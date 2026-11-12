# Premium workspace (needed for Unity Catalog) plus the access connector that UC uses to reach ADLS.

variable "name" { type = string }
variable "access_connector_name" { type = string }
variable "resource_group_name" { type = string }
variable "location" { type = string }
variable "tags" { type = map(string) }

resource "azurerm_databricks_workspace" "this" {
  name                        = var.name
  resource_group_name         = var.resource_group_name
  location                    = var.location
  sku                         = "premium"
  managed_resource_group_name = "${var.name}-managed"
  tags                        = var.tags
}

resource "azurerm_databricks_access_connector" "this" {
  name                = var.access_connector_name
  resource_group_name = var.resource_group_name
  location            = var.location
  tags                = var.tags

  identity {
    type = "SystemAssigned"
  }
}

output "id" { value = azurerm_databricks_workspace.this.id }
output "url" { value = "https://${azurerm_databricks_workspace.this.workspace_url}" }
output "access_connector_id" { value = azurerm_databricks_access_connector.this.id }
output "access_connector_principal_id" {
  value = azurerm_databricks_access_connector.this.identity[0].principal_id
}
