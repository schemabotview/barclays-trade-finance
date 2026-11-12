output "databricks_url" { value = module.databricks.url }
output "storage_account" { value = module.adls.name }
output "key_vault_uri" { value = module.keyvault.uri }
output "data_factory" { value = module.adf.name }
output "catalog" { value = module.unity_catalog.catalog }
output "cluster_policy_id" { value = module.cluster_policy.id }
output "postgres_fqdn" { value = module.postgres.fqdn }
