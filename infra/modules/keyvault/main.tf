# Key Vault in RBAC mode. Access is granted with role assignments, not access policies.

variable "name" { type = string }
variable "resource_group_name" { type = string }
variable "location" { type = string }
variable "tenant_id" { type = string }
variable "purge_protection" { type = bool }
variable "tags" { type = map(string) }

resource "azurerm_key_vault" "this" {
  name                       = var.name
  resource_group_name        = var.resource_group_name
  location                   = var.location
  tenant_id                  = var.tenant_id
  sku_name                   = "standard"
  rbac_authorization_enabled = true
  soft_delete_retention_days = 7
  purge_protection_enabled   = var.purge_protection
  tags                       = var.tags
}

output "id" { value = azurerm_key_vault.this.id }
output "uri" { value = azurerm_key_vault.this.vault_uri }
