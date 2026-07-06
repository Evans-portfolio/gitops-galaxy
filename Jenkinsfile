pipeline {
  agent any

  environment {
    ARGOCD_SERVER = '192.168.49.2:30443'
    GIT_REPO_URL  = 'https://gitea.kood.tech/evanschepkwony1/gitops-galaxy.git'
    APP_NAME      = 'sorcery-app'
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

            sed -i "s/appEnvironment: .*/appEnvironment: \\"ci-build-${BUILD_NUMBER}\\"/" charts/sorcery-chart/values.yaml

            git add charts/sorcery-chart/values.yaml
            git commit -m "ci: pipeline build ${BUILD_NUMBER} - update appEnvironment"
            git push "https://${GIT_USER}:${GIT_TOKEN}@gitea.kood.tech/evanschepkwony1/gitops-galaxy.git" HEAD:main
          '''
        }
      }
    }

    stage('Apply ArgoCD Application') {
      steps {
        withCredentials([file(credentialsId: 'jenkins-kubeconfig', variable: 'KUBECONFIG')]) {
          sh 'kubectl apply -f manifests/argocd/application.yaml'
        }
      }
    }

    stage('ArgoCD sync & wait for health') {
      steps {
        withCredentials([string(credentialsId: 'argocd-jenkins-token', variable: 'ARGOCD_TOKEN')]) {
          sh '''
            set -e
            argocd app sync "${APP_NAME}" --auth-token "${ARGOCD_TOKEN}" --server "${ARGOCD_SERVER}" --insecure
            argocd app wait "${APP_NAME}" --health --timeout 300 --auth-token "${ARGOCD_TOKEN}" --server "${ARGOCD_SERVER}" --insecure
          '''
        }
      }
    }
  }

  post {
    failure {
      echo "Pipeline failed — rolling back the manifest change and re-syncing."
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
          argocd app sync "${APP_NAME}" --auth-token "${ARGOCD_TOKEN}" --server "${ARGOCD_SERVER}" --insecure
          argocd app wait "${APP_NAME}" --health --timeout 300 --auth-token "${ARGOCD_TOKEN}" --server "${ARGOCD_SERVER}" --insecure
        '''
      }
    }
  }
}
