# Data Factory with a managed identity and linked services to ADLS, Key Vault and the TradeBook
# PostgreSQL source. Everything is in Azure, so all of them use the default Azure integration runtime.

variable "name" { type = string }
variable "resource_group_name" { type = string }
variable "location" { type = string }
variable "adls_dfs_endpoint" { type = string }
variable "key_vault_id" { type = string }
variable "postgres_fqdn" { type = string }
variable "postgres_database" { type = string }
variable "postgres_user" { type = string }
variable "postgres_password_secret" { type = string }
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

# Connector version 2.0; `version` sits beside `type`, so it goes in additional_properties.
resource "azurerm_data_factory_linked_custom_service" "tradebook" {
  name            = "ls_tradebook_pg"
  data_factory_id = azurerm_data_factory.this.id
  type            = "AzurePostgreSql"
  description     = "TradeBook source (Azure Database for PostgreSQL Flexible Server)"
  additional_properties = {
    version = "2.0"
  }
  type_properties_json = jsonencode({
    server             = var.postgres_fqdn
    port               = 5432
    database           = var.postgres_database
    sslMode            = 3
    authenticationType = "Basic"
    username           = var.postgres_user
    password = {
      type       = "AzureKeyVaultSecret"
      secretName = var.postgres_password_secret
      store = {
        referenceName = azurerm_data_factory_linked_service_key_vault.kv.name
        type          = "LinkedServiceReference"
      }
    }
  })
}

output "id" { value = azurerm_data_factory.this.id }
output "name" { value = azurerm_data_factory.this.name }
output "principal_id" { value = azurerm_data_factory.this.identity[0].principal_id }
