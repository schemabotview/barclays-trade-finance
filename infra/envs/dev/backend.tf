terraform {
  required_version = ">= 1.9"

  required_providers {
    azurerm    = { source = "hashicorp/azurerm", version = "~> 4.0" }
    databricks = { source = "databricks/databricks", version = "~> 1.0" }
    random     = { source = "hashicorp/random", version = "~> 3.6" }
    time       = { source = "hashicorp/time", version = "~> 0.12" }
  }

  # Created in bootstrap (IMPLEMENTATION-PLAN.md, phase 0). Entra auth: no storage keys.
  backend "azurerm" {
    resource_group_name  = "rg-tfstate-uks"
    storage_account_name = "sttfstate8014mr"
    container_name       = "tfstate"
    key                  = "lcexp-dev.tfstate"
    use_azuread_auth     = true
  }
}

# Auth: OIDC in GitHub Actions (ARM_USE_OIDC + ARM_CLIENT_ID / ARM_TENANT_ID / ARM_SUBSCRIPTION_ID),
# the az CLI login locally. Both providers read the same variables.
provider "azurerm" {
  features {
    key_vault {
      purge_soft_delete_on_destroy = true
    }
  }
  storage_use_azuread = true
}

provider "databricks" {
  host                        = module.databricks.url
  azure_workspace_resource_id = module.databricks.id
}
