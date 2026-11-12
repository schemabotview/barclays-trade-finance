# Resources (dev)

What `infra/envs/dev` creates and why: 38 resources in `rg-lcexp-dev-uks`.

## Source: TradeBook

| # | Resource | Purpose |
|---|---|---|
| 1 | `azurerm_postgresql_flexible_server` (`psql-lcexp-dev-<suffix>`) | The TradeBook source system: PostgreSQL 16, Burstable `B_Standard_B1ms`. It runs in Azure, not on-prem, to keep the build simple, so no self-hosted integration runtime is needed. |
| 2 | `azurerm_postgresql_flexible_server_database` (`tradebook`) | The database that holds the LC deals and amendments. |
| 3 | `azurerm_postgresql_flexible_server_firewall_rule` (`AllowAzureServices`) | Lets Azure services, including ADF, connect. ADF's Azure integration runtime has no fixed IP. |
| 4 | `azurerm_key_vault_secret` (`pg-tradebook-password`) | The `tradebook_admin` password. It is generated as an ephemeral value and written only to the server and Key Vault, never to Terraform state. |

## Data Factory: moves the data in

| # | Resource | Purpose |
|---|---|---|
| 5 | `azurerm_data_factory` (`adf-lcexp-dev-uks`) | Runs the pipelines that copy source data into the lake. It has its own managed identity. |
| 6 | `azurerm_data_factory_linked_service_data_lake_storage_gen2` (`ls_adls`) | ADF's saved connection to the data lake, where it writes files and the watermark JSON. |
| 7 | `azurerm_data_factory_linked_service_key_vault` (`ls_key_vault`) | ADF's connection to Key Vault, so other linked services read passwords from there instead of storing them. |
| 8 | `azurerm_data_factory_linked_custom_service` (`ls_tradebook_pg`) | ADF's connection to TradeBook: Azure Database for PostgreSQL connector 2.0, TLS required, password from Key Vault (4). |

## Data lake: ADLS Gen2

| # | Resource | Purpose |
|---|---|---|
| 9 | `azurerm_storage_account` (`stlcexpdev<suffix>`) | The data lake itself, with hierarchical namespace turned on. |
| 10 | container `landing` | Raw extracts exactly as ADF delivers them, one folder per `batch_id`. Also holds the extraction watermark, `_control/lc_deals_watermark.json`. |
| 11 | container `bronze` | Raw data loaded into Delta tables. |
| 12 | container `silver` | Cleaned, conformed data. |
| 13 | container `gold` | Business-ready aggregates, e.g. LC exposure. |
| 14 | container `checkpoints` | Streaming and Auto Loader checkpoints, which record what has already been processed. |
| 15 | container `catalog` | Storage root for the `risk` catalog's managed tables. |

## Secrets

| # | Resource | Purpose |
|---|---|---|
| 16 | `azurerm_key_vault` (`kv-lcexp-dev-<suffix>`) | Holds secrets such as the TradeBook password. Access is controlled with Azure role assignments, not vault access policies. |

## Databricks platform

| # | Resource | Purpose |
|---|---|---|
| 17 | `azurerm_databricks_workspace` (`dbw-lcexp-dev-uks`) | The Premium workspace where notebooks and jobs run. Premium is needed for Unity Catalog. |
| 18 | `azurerm_databricks_access_connector` (`ac-lcexp-dev`) | A managed identity that Unity Catalog uses to read and write the lake. No keys are involved. |

## Unity Catalog: governance over the lake

| # | Resource | Purpose |
|---|---|---|
| 19 | `databricks_storage_credential` (`lcexp-dev-adls`) | Registers the access connector with Unity Catalog. |
| 20–25 | `databricks_external_location` × 6 (one per container) | Each pairs a container path with the credential. Unity Catalog then controls who may use that path, instead of the path being open to anyone with storage access. |
| 26 | `databricks_catalog` (`risk`) | The top-level namespace for this project's tables, stored in the `catalog` container. |
| 27–29 | `databricks_schema` `bronze` / `silver` / `gold` | The medallion layers as schemas, so tables are named like `risk.silver.lc_current`. |
| 30 | `databricks_grants.catalog` | Who may use the `risk` catalog and what they can do (from the `catalog_grants` variable). |

## Compute guardrail

| # | Resource | Purpose |
|---|---|---|
| 31 | `databricks_cluster_policy` (`lcexp-dev-single-node`) | Limits clusters to single-node, a fixed VM size and single-user security mode, with auto-termination after 15 minutes. This keeps cost and vCPU quota down. |

## Role assignments: who can reach what

| # | Resource | Purpose |
|---|---|---|
| 32 | `azurerm_role_assignment.uc_adls` | Gives the access connector Storage Blob Data Contributor on the lake, so Unity Catalog can read and write it. |
| 33 | `azurerm_role_assignment.uc_connector` | Gives the access connector Reader on itself, which Unity Catalog's storage-credential check can ask for. |
| 34 | `azurerm_role_assignment.adf_adls` | Gives ADF's identity Storage Blob Data Contributor on the lake, so it can write to `landing`. |
| 35 | `azurerm_role_assignment.adf_kv` | Gives ADF's identity Key Vault Secrets User, so it can read secrets but not change them. |
| 36 | `azurerm_role_assignment.runner_kv` | Gives whoever runs Terraform (`sp-cicd-lcexp` in CI) Key Vault Secrets Officer, so it can write the TradeBook password. |

## Helpers: no Azure resource behind them

| # | Resource | Purpose |
|---|---|---|
| 37 | `random_string.suffix` | A random suffix, because storage account, Key Vault and PostgreSQL server names must be unique across all of Azure. |
| 38 | `time_sleep.rbac` | A 90-second pause. New role assignments take a minute or so to take effect, and Unity Catalog and the Key Vault secret write both depend on them. |

The PostgreSQL password comes from an ephemeral `random_password`, which isn't a resource and
isn't counted: it exists only while Terraform runs.

## How they fit together

```
TradeBook PostgreSQL ──▶ ADF Copy (Azure IR, password from Key Vault) ──▶ landing/lc_deals/batch_id=<n>/
                           ▲  reads/writes landing/_control/lc_deals_watermark.json
landing ──▶ Auto Loader ──▶ bronze ──▶ silver ──▶ gold      (Databricks, governed by Unity Catalog)
```

The sources are TradeBook PostgreSQL (LC deals and amendments, extracted by watermark) and
reference files (counterparty groups, limits); see `REQUIREMENTS.md` §1. ADF (5) reads TradeBook
(1–2) through its linked service (8), which takes the password from Key Vault (4, 7, 16). It
writes each batch to `landing` (10) as files with a manifest, so database rows and reference files
are processed the same way from there on. Databricks (17) processes them into bronze, silver and
gold (11–13), and Unity Catalog (19–30) controls access through the access connector (18). The
cluster policy (31) keeps compute small, and the role assignments (32–36) make each identity's
access explicit.

## Not created yet

Phase 7 (Extraction) seeds TradeBook (schema and sample LCs), adds a read-only `adf_reader` role
for ADF in place of the admin login, and builds the Copy pipeline with the watermark JSON.
