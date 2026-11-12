# Storage credential (the access connector), one external location per container, the
# catalog and one schema per medallion layer, each stored in its own container.

terraform {
  required_providers {
    databricks = { source = "databricks/databricks" }
  }
}

variable "prefix" { type = string }
variable "access_connector_id" { type = string }
variable "locations" {
  description = "container → abfss:// URL"
  type        = map(string)
}
variable "catalog" { type = string }
variable "catalog_container" { type = string }
variable "schemas" {
  description = "schema → container"
  type        = map(string)
}
variable "catalog_grants" {
  description = "principal → privileges on the catalog"
  type        = map(list(string))
}

resource "databricks_storage_credential" "adls" {
  name          = "${var.prefix}-adls"
  force_destroy = true

  azure_managed_identity {
    access_connector_id = var.access_connector_id
  }
}

resource "databricks_external_location" "this" {
  for_each        = var.locations
  name            = "${var.prefix}-${each.key}"
  url             = each.value
  credential_name = databricks_storage_credential.adls.id
  force_destroy   = true
}

resource "databricks_catalog" "this" {
  name          = var.catalog
  storage_root  = var.locations[var.catalog_container]
  force_destroy = true
  depends_on    = [databricks_external_location.this]
}

resource "databricks_schema" "this" {
  for_each      = var.schemas
  catalog_name  = databricks_catalog.this.name
  name          = each.key
  storage_root  = var.locations[each.value]
  force_destroy = true
  depends_on    = [databricks_external_location.this]
}

resource "databricks_grants" "catalog" {
  catalog = databricks_catalog.this.name

  dynamic "grant" {
    for_each = var.catalog_grants
    content {
      principal  = grant.key
      privileges = grant.value
    }
  }
}

output "catalog" { value = databricks_catalog.this.name }
output "external_locations" { value = { for k, v in databricks_external_location.this : k => v.url } }
