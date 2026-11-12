# TradeBook source: Azure Database for PostgreSQL Flexible Server. The admin password is ephemeral and
# write-only: Terraform sets it on the server and in Key Vault, and never stores it in state.

variable "name" { type = string }
variable "resource_group_name" { type = string }
variable "location" { type = string }
variable "database" { type = string }
variable "admin_login" { type = string }
variable "key_vault_id" { type = string }
variable "password_secret_name" { type = string }
variable "tags" { type = map(string) }

ephemeral "random_password" "admin" {
  length      = 32
  special     = false
  min_lower   = 1
  min_upper   = 1
  min_numeric = 1
}

resource "azurerm_postgresql_flexible_server" "this" {
  name                              = var.name
  resource_group_name               = var.resource_group_name
  location                          = var.location
  version                           = "16"
  sku_name                          = "B_Standard_B1ms"
  storage_mb                        = 32768
  backup_retention_days             = 7
  administrator_login               = var.admin_login
  administrator_password_wo         = ephemeral.random_password.admin.result
  administrator_password_wo_version = 1
  tags                              = var.tags

  authentication {
    password_auth_enabled         = true
    active_directory_auth_enabled = false
  }

  # Azure picks the zone; pinning it would force a replace.
  lifecycle {
    ignore_changes = [zone]
  }
}

resource "azurerm_postgresql_flexible_server_database" "this" {
  name      = var.database
  server_id = azurerm_postgresql_flexible_server.this.id
  charset   = "UTF8"
  collation = "en_US.utf8"
}

# 0.0.0.0 = "allow Azure services": ADF's Azure integration runtime has no fixed IP.
resource "azurerm_postgresql_flexible_server_firewall_rule" "azure" {
  name             = "AllowAzureServices"
  server_id        = azurerm_postgresql_flexible_server.this.id
  start_ip_address = "0.0.0.0"
  end_ip_address   = "0.0.0.0"
}

# Bump value_wo_version together with administrator_password_wo_version to rotate.
resource "azurerm_key_vault_secret" "password" {
  name             = var.password_secret_name
  key_vault_id     = var.key_vault_id
  value_wo         = ephemeral.random_password.admin.result
  value_wo_version = 1
  content_type     = "password for ${var.admin_login}@${var.name}"
}

output "fqdn" { value = azurerm_postgresql_flexible_server.this.fqdn }
output "database" { value = azurerm_postgresql_flexible_server_database.this.name }
output "admin_login" { value = var.admin_login }
output "password_secret_name" { value = azurerm_key_vault_secret.password.name }
