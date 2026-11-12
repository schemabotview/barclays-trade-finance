// LC exposure CI/CD (Multibranch Pipeline, GitHub branch source).
//
//   pull request → tests, fmt/validate, plan dev           (nothing changes in Azure)
//   merge to main → tests, fmt/validate, plan dev → apply dev → bundle deploy dev
//   test / prod   → same stages behind an `input` approval, once those envs exist
//
// Credential `azure-sp-lcexp` is the Azure Service Principal for sp-jenkins-lcexp.

def tf(String envName, String args) {
  sh "terraform -chdir=infra/envs/${envName} ${args}"
}

def withAzure(Closure body) {
  withCredentials([azureServicePrincipal(
      credentialsId: 'azure-sp-lcexp',
      subscriptionIdVariable: 'ARM_SUBSCRIPTION_ID',
      clientIdVariable: 'ARM_CLIENT_ID',
      clientSecretVariable: 'ARM_CLIENT_SECRET',
      tenantIdVariable: 'ARM_TENANT_ID')]) {
    body()
  }
}

pipeline {
  agent any

  options {
    timestamps()
    ansiColor('xterm')
    disableConcurrentBuilds()   // per branch; across branches the state lock serialises
    buildDiscarder(logRotator(numToKeepStr: '20'))
  }

  environment {
    PATH             = "/opt/homebrew/bin:${env.PATH}"
    TF_IN_AUTOMATION = 'true'
    TF_INPUT         = '0'
  }

  stages {
    stage('Lint + unit tests') {
      when { expression { fileExists('tests') } }
      steps {
        sh '''
          python3 -m venv .venv && . .venv/bin/activate
          pip install -q -r requirements-dev.txt
          ruff check src tests
          pytest -q --junitxml=reports/pytest.xml
        '''
      }
      post { always { junit allowEmptyResults: true, testResults: 'reports/*.xml' } }
    }

    stage('Terraform fmt + validate') {
      steps {
        sh 'terraform fmt -check -recursive infra'
        tf('dev', 'init -backend=false')
        tf('dev', 'validate')
      }
    }

    stage('Plan dev') {
      when { anyOf { changeRequest(); branch 'main' } }
      steps {
        withAzure {
          tf('dev', 'init -reconfigure')
          // -detailed-exitcode: 0 = no changes, 2 = changes, 1 = error
          script {
            def rc = sh(returnStatus: true,
                        script: 'terraform -chdir=infra/envs/dev plan -lock-timeout=10m -detailed-exitcode -out=tfplan')
            if (rc == 1) { error 'terraform plan failed' }
            env.DEV_HAS_CHANGES = (rc == 2) ? 'true' : 'false'
          }
          tf('dev', 'show -no-color tfplan > plan-dev.txt')
        }
        archiveArtifacts artifacts: 'infra/envs/dev/plan-dev.txt'
        script {
          currentBuild.description = env.DEV_HAS_CHANGES == 'true' ? 'dev: changes planned' : 'dev: no changes'
        }
      }
    }

    // Applies the exact plan reviewed above; a merge to main is the approval for dev.
    stage('Apply dev') {
      when { allOf { branch 'main'; expression { env.DEV_HAS_CHANGES == 'true' } } }
      steps {
        withAzure { tf('dev', 'apply -lock-timeout=10m tfplan') }
      }
    }

    // Jobs ship as a Databricks Asset Bundle (phase 3+). Skipped until databricks.yml exists.
    stage('Deploy bundle dev') {
      when { allOf { branch 'main'; expression { fileExists('databricks.yml') } } }
      steps {
        withAzure {
          sh '''
            export DATABRICKS_HOST=$(terraform -chdir=infra/envs/dev output -raw databricks_url)
            export DATABRICKS_AUTH_TYPE=azure-client-secret
            export DATABRICKS_AZURE_CLIENT_ID=$ARM_CLIENT_ID
            export DATABRICKS_AZURE_CLIENT_SECRET=$ARM_CLIENT_SECRET
            export DATABRICKS_AZURE_TENANT_ID=$ARM_TENANT_ID
            databricks bundle validate -t dev
            databricks bundle deploy -t dev
          '''
        }
      }
    }

    // test / prod (once infra/envs/{test,prod} exist and the vCPU quota allows):
    //   stage('Plan test') → stage('Approve test') { input … } → stage('Apply test'), then prod,
    //   each `when { branch 'main' }`; prod uses its own SP credential.
  }

  post {
    always { sh 'rm -f infra/envs/*/tfplan' }
  }
}
