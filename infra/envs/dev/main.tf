variable "env" { type = string }
variable "location" { type = string }
variable "node_type" { type = string }
variable "catalog_grants" { type = map(list(string)) }

locals {
  prefix     = "lcexp-${var.env}"
  containers = ["landing", "bronze", "silver", "gold", "checkpoints", "catalog"]
  tags       = { project = "lcexp", env = var.env, managed_by = "terraform" }
}

data "azurerm_client_config" "current" {}

# Created in bootstrap; the Jenkins SP is scoped to it and cannot create resource groups.
data "azurerm_resource_group" "this" {
  name = "rg-${local.prefix}-uks"
}

resource "random_string" "suffix" {
  length  = 6
  upper   = false
  special = false
}

module "adls" {
  source              = "../../modules/adls"
  name                = "stlcexp${var.env}${random_string.suffix.result}"
  resource_group_name = data.azurerm_resource_group.this.name
  location            = var.location
  containers          = local.containers
  tags                = local.tags
}

module "keyvault" {
  source              = "../../modules/keyvault"
  name                = "kv-${local.prefix}-${random_string.suffix.result}"
  resource_group_name = data.azurerm_resource_group.this.name
  location            = var.location
  tenant_id           = data.azurerm_client_config.current.tenant_id
  purge_protection    = false
  tags                = local.tags
}

module "adf" {
  source              = "../../modules/adf"
  name                = "adf-${local.prefix}-uks"
  resource_group_name = data.azurerm_resource_group.this.name
  location            = var.location
  adls_dfs_endpoint   = module.adls.dfs_endpoint
  key_vault_id        = module.keyvault.id
  tags                = local.tags
}

module "databricks" {
  source                = "../../modules/databricks_workspace"
  name                  = "dbw-${local.prefix}-uks"
  access_connector_name = "ac-${local.prefix}"
  resource_group_name   = data.azurerm_resource_group.this.name
  location              = var.location
  tags                  = local.tags
}

# --- Role assignments (the Jenkins SP holds Role Based Access Control Administrator on the RG)

resource "azurerm_role_assignment" "uc_adls" {
  scope                = module.adls.id
  role_definition_name = "Storage Blob Data Contributor"
  principal_id         = module.databricks.access_connector_principal_id
  principal_type       = "ServicePrincipal"
}

resource "azurerm_role_assignment" "adf_adls" {
  scope                = module.adls.id
  role_definition_name = "Storage Blob Data Contributor"
  principal_id         = module.adf.principal_id
  principal_type       = "ServicePrincipal"
}

resource "azurerm_role_assignment" "adf_kv" {
  scope                = module.keyvault.id
  role_definition_name = "Key Vault Secrets User"
  principal_id         = module.adf.principal_id
  principal_type       = "ServicePrincipal"
}

# RBAC takes a minute to reach the data plane; UC validates the location on create.
resource "time_sleep" "rbac" {
  depends_on      = [azurerm_role_assignment.uc_adls]
  create_duration = "90s"
}

# --- Databricks workspace contents

module "unity_catalog" {
  source              = "../../modules/unity_catalog"
  prefix              = local.prefix
  access_connector_id = module.databricks.access_connector_id
  locations           = module.adls.abfss
  catalog             = "risk"
  catalog_container   = "catalog"
  schemas             = { bronze = "bronze", silver = "silver", gold = "gold" }
  catalog_grants      = var.catalog_grants
  depends_on          = [time_sleep.rbac]
}

module "cluster_policy" {
  source                  = "../../modules/cluster_policy"
  name                    = "${local.prefix}-single-node"
  node_type               = var.node_type
  autotermination_minutes = 15
}
