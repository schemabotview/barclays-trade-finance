# Data Factory with a managed identity, linked services to ADLS and Key Vault, and a
# self-hosted IR for on-prem TradeBook. The SHIR node is registered by hand with the auth key.

variable "name" { type = string }
variable "resource_group_name" { type = string }
variable "location" { type = string }
variable "adls_dfs_endpoint" { type = string }
variable "key_vault_id" { type = string }
variable "tags" { type = map(string) }

resource "azurerm_data_factory" "this" {
  name                = var.name
  resource_group_name = var.resource_group_name
  location            = var.location
  tags                = var.tags

  identity {
    type = "SystemAssigned"
  }
}

resource "azurerm_data_factory_linked_service_data_lake_storage_gen2" "adls" {
  name                 = "ls_adls"
  data_factory_id      = azurerm_data_factory.this.id
  url                  = var.adls_dfs_endpoint
  use_managed_identity = true
}

resource "azurerm_data_factory_linked_service_key_vault" "kv" {
  name            = "ls_key_vault"
  data_factory_id = azurerm_data_factory.this.id
  key_vault_id    = var.key_vault_id
}

resource "azurerm_data_factory_integration_runtime_self_hosted" "shir" {
  name            = "shir-tradebook"
  data_factory_id = azurerm_data_factory.this.id
  description     = "On-prem TradeBook PostgreSQL"
}

output "id" { value = azurerm_data_factory.this.id }
output "name" { value = azurerm_data_factory.this.name }
output "principal_id" { value = azurerm_data_factory.this.identity[0].principal_id }
