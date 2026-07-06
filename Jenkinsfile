pipeline {
  agent any

  environment {
    ARGOCD_SERVER = '192.168.49.2:30443'
    GIT_REPO_URL  = 'https://gitea.kood.tech/evanschepkwony1/gitops-galaxy.git'
  }

  stages {
    stage('Checkout') {
      steps {
        checkout([$class: 'GitSCM',
          branches: [[name: '*/main']],
          userRemoteConfigs: [[
            url: env.GIT_REPO_URL,
            credentialsId: 'gitea-jenkins-token'
          ]]
        ])
      }
    }

    stage('Commit & push manifest change') {
      steps {
        withCredentials([usernamePassword(credentialsId: 'gitea-jenkins-token',
                                           usernameVariable: 'GIT_USER',
                                           passwordVariable: 'GIT_TOKEN')]) {
          sh '''
            set -e
            git config user.email "jenkins-ci@sorcery.local"
            git config user.name "jenkins-ci"

            sed -i "s/lastCIBuild: .*/lastCIBuild: \\"${BUILD_NUMBER}\\"/" charts/sorcery-chart/values.yaml
            # TEMPORARY: deliberately break staging only (dev/production
            # unaffected, since this overrides the tag in the staging
            # overlay only) to test the multi-env rollback end-to-end.
            # Remove after the test.
            cat > charts/sorcery-chart/values-staging.yaml << "STAGING_EOF"
namespace: staging
ingress:
  host: staging.gitops.local
frontend:
  replicaCount: 2
  image:
    tag: "1.27.9999-does-not-exist"
  hpa:
    enabled: true
    minReplicas: 2
    maxReplicas: 4
    targetCPUUtilizationPercentage: 70
config:
  appEnvironment: "staging"
STAGING_EOF

            git add charts/sorcery-chart/values.yaml charts/sorcery-chart/values-staging.yaml
            git commit -m "ci: pipeline build ${BUILD_NUMBER} - update lastCIBuild"
            git push "https://${GIT_USER}:${GIT_TOKEN}@gitea.kood.tech/evanschepkwony1/gitops-galaxy.git" HEAD:main
          '''
        }
      }
    }

    stage('Deploy to Dev') {
      steps {
        withCredentials([file(credentialsId: 'jenkins-kubeconfig', variable: 'KUBECONFIG')]) {
          sh 'kubectl apply -f manifests/argocd/application-dev.yaml'
        }
        withCredentials([string(credentialsId: 'argocd-jenkins-token', variable: 'ARGOCD_TOKEN')]) {
          sh '''
            set -e
            argocd app sync sorcery-app-dev --auth-token "${ARGOCD_TOKEN}" --server "${ARGOCD_SERVER}" --insecure
            argocd app wait sorcery-app-dev --health --timeout 120 --auth-token "${ARGOCD_TOKEN}" --server "${ARGOCD_SERVER}" --insecure
          '''
        }
      }
    }

    stage('Deploy to Staging') {
      steps {
        withCredentials([file(credentialsId: 'jenkins-kubeconfig', variable: 'KUBECONFIG')]) {
          sh 'kubectl apply -f manifests/argocd/application-staging.yaml'
        }
        withCredentials([string(credentialsId: 'argocd-jenkins-token', variable: 'ARGOCD_TOKEN')]) {
          sh '''
            set -e
            argocd app sync sorcery-app-staging --auth-token "${ARGOCD_TOKEN}" --server "${ARGOCD_SERVER}" --insecure
            argocd app wait sorcery-app-staging --health --timeout 300 --auth-token "${ARGOCD_TOKEN}" --server "${ARGOCD_SERVER}" --insecure
          '''
        }
      }
    }

    stage('Promote to production?') {
      steps {
        input message: 'Staging is healthy. Promote this build to production?', ok: 'Deploy to production'
      }
    }

    stage('Deploy to Production') {
      steps {
        withCredentials([file(credentialsId: 'jenkins-kubeconfig', variable: 'KUBECONFIG')]) {
          sh 'kubectl apply -f manifests/argocd/application-production.yaml'
        }
        withCredentials([string(credentialsId: 'argocd-jenkins-token', variable: 'ARGOCD_TOKEN')]) {
          sh '''
            set -e
            argocd app sync sorcery-app-production --auth-token "${ARGOCD_TOKEN}" --server "${ARGOCD_SERVER}" --insecure
            argocd app wait sorcery-app-production --health --timeout 300 --auth-token "${ARGOCD_TOKEN}" --server "${ARGOCD_SERVER}" --insecure
          '''
        }
      }
    }
  }

  post {
    failure {
      echo "Pipeline failed — rolling back the manifest change and re-syncing all environments."
      withCredentials([
        usernamePassword(credentialsId: 'gitea-jenkins-token', usernameVariable: 'GIT_USER', passwordVariable: 'GIT_TOKEN'),
        string(credentialsId: 'argocd-jenkins-token', variable: 'ARGOCD_TOKEN')
      ]) {
        sh '''
          set -e
          git config user.email "jenkins-ci@sorcery.local"
          git config user.name "jenkins-ci"
          git revert --no-edit HEAD
          git push "https://${GIT_USER}:${GIT_TOKEN}@gitea.kood.tech/evanschepkwony1/gitops-galaxy.git" HEAD:main

          for app in sorcery-app-dev sorcery-app-staging sorcery-app-production; do
            argocd app sync "$app" --auth-token "${ARGOCD_TOKEN}" --server "${ARGOCD_SERVER}" --insecure
            argocd app wait "$app" --health --timeout 300 --auth-token "${ARGOCD_TOKEN}" --server "${ARGOCD_SERVER}" --insecure
          done
        '''
      }
    }
  }
}
