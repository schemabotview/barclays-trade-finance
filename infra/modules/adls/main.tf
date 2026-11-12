# ADLS Gen2 account with one container per layer. Entra auth only (no shared keys).

variable "name" { type = string }
variable "resource_group_name" { type = string }
variable "location" { type = string }
variable "containers" { type = list(string) }
variable "tags" { type = map(string) }

resource "azurerm_storage_account" "this" {
  name                            = var.name
  resource_group_name             = var.resource_group_name
  location                        = var.location
  account_tier                    = "Standard"
  account_replication_type        = "LRS"
  account_kind                    = "StorageV2"
  is_hns_enabled                  = true
  min_tls_version                 = "TLS1_2"
  https_traffic_only_enabled      = true
  shared_access_key_enabled       = false
  allow_nested_items_to_be_public = false
  tags                            = var.tags

  blob_properties {
    delete_retention_policy {
      days = 7
    }
    container_delete_retention_policy {
      days = 7
    }
  }
}

# storage_account_id → created through ARM, so no data-plane role is needed.
resource "azurerm_storage_container" "this" {
  for_each           = toset(var.containers)
  name               = each.key
  storage_account_id = azurerm_storage_account.this.id
}

output "id" { value = azurerm_storage_account.this.id }
output "name" { value = azurerm_storage_account.this.name }
output "dfs_endpoint" { value = azurerm_storage_account.this.primary_dfs_endpoint }

# abfss://<container>@<account>.dfs.core.windows.net/
output "abfss" {
  value = { for c in var.containers : c => "abfss://${c}@${azurerm_storage_account.this.name}.dfs.core.windows.net/" }
}
