// LC exposure: test → Terraform plan → (approve) apply → Databricks bundle deploy.
// Credential `azure-sp-lcexp` is the Azure Service Principal for sp-jenkins-lcexp.

def tf(String envName, String args) {
  sh "terraform -chdir=infra/envs/${envName} ${args}"
}

pipeline {
  agent any

  options {
    timestamps()
    ansiColor('xterm')
    disableConcurrentBuilds()   // one state lock, one 4-vCPU cluster
    buildDiscarder(logRotator(numToKeepStr: '20'))
  }

  parameters {
    booleanParam(name: 'APPLY', defaultValue: false, description: 'Apply to dev after the plan (main branch only)')
  }

  environment {
    PATH         = "/opt/homebrew/bin:${env.PATH}"
    TF_IN_AUTOMATION = 'true'
    TF_INPUT     = '0'
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
      steps {
        withCredentials([azureServicePrincipal(
            credentialsId: 'azure-sp-lcexp',
            subscriptionIdVariable: 'ARM_SUBSCRIPTION_ID',
            clientIdVariable: 'ARM_CLIENT_ID',
            clientSecretVariable: 'ARM_CLIENT_SECRET',
            tenantIdVariable: 'ARM_TENANT_ID')]) {
          tf('dev', 'init -reconfigure')
          tf('dev', 'plan -out=tfplan')
          tf('dev', 'show -no-color tfplan > plan-dev.txt')
        }
        archiveArtifacts artifacts: 'infra/envs/dev/plan-dev.txt'
      }
    }

    stage('Approve dev') {
      when { allOf { expression { params.APPLY }; expression { (env.BRANCH_NAME ?: 'main') == 'main' } } }
      steps {
        timeout(time: 30, unit: 'MINUTES') {
          input message: 'Apply plan-dev.txt to dev?', ok: 'Apply'
        }
      }
    }

    stage('Apply dev') {
      when { allOf { expression { params.APPLY }; expression { (env.BRANCH_NAME ?: 'main') == 'main' } } }
      steps {
        withCredentials([azureServicePrincipal(
            credentialsId: 'azure-sp-lcexp',
            subscriptionIdVariable: 'ARM_SUBSCRIPTION_ID',
            clientIdVariable: 'ARM_CLIENT_ID',
            clientSecretVariable: 'ARM_CLIENT_SECRET',
            tenantIdVariable: 'ARM_TENANT_ID')]) {
          tf('dev', 'apply tfplan')
        }
      }
    }

    // Jobs ship as a Databricks Asset Bundle (phase 3+). Skipped until databricks.yml exists.
    stage('Deploy bundle dev') {
      when { allOf { expression { params.APPLY }; expression { fileExists('databricks.yml') } } }
      steps {
        withCredentials([azureServicePrincipal(
            credentialsId: 'azure-sp-lcexp',
            subscriptionIdVariable: 'ARM_SUBSCRIPTION_ID',
            clientIdVariable: 'ARM_CLIENT_ID',
            clientSecretVariable: 'ARM_CLIENT_SECRET',
            tenantIdVariable: 'ARM_TENANT_ID')]) {
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

    // test / prod: add infra/envs/{test,prod} and copy the Plan → Approve → Apply stages
    // once the vCPU quota allows a second cluster.
  }

  post {
    always { sh 'rm -f infra/envs/*/tfplan' }
  }
}
