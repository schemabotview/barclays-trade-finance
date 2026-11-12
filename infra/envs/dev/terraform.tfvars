env       = "dev"
location  = "uksouth"
node_type = "Standard_DS3_v2" # 4 vCPU: the whole regional quota

# Dev only: everyone in the Databricks account can build in the catalog.
catalog_grants = {
  "account users" = ["ALL_PRIVILEGES"]
}
