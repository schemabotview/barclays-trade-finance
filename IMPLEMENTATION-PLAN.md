# Implementation Plan — LC Exposure by Group

Delivers [REQUIREMENTS.md](REQUIREMENTS.md). Stack: Azure, Databricks, Terraform, GitHub Actions.

## Target environment

| item | value |
|---|---|
| Subscription | `5cd3e971-2e20-49fb-95bc-021190718075` (Azure subscription 1, Default Directory) |
| Tenant | `9a1807cc-1918-4a95-ad1e-17b6555bba94`; you are Owner + Global Administrator |
| Region | `uksouth` |
| Quota | 4 vCPUs regional → one single-node `Standard_DS3_v2` cluster, 15 min auto-terminate; jobs run one at a time |
| CI/CD | GitHub Actions on `schemabotview/barclays-trade-finance`, GitHub-hosted runners, OIDC to Azure |

Names (one `env` suffix each; dev only until quota is raised):

| resource | name |
|---|---|
| TF state ✅ | `rg-tfstate-uks` (delete lock) / `sttfstate8014mr` (Entra auth only, versioning, 30-day soft delete) / container `tfstate`, key `lcexp-<env>.tfstate` |
| Resource group ✅ | `rg-lcexp-<env>-uks`, created in bootstrap; Terraform reads it (`data`), never creates it |
| ADLS Gen2 | `stlcexp<env><rand>`: containers `landing`, `bronze`, `silver`, `gold`, `checkpoints`, `catalog` (UC catalog root) |
| Key Vault | `kv-lcexp-<env>-<rand>` (RBAC mode) |
| Data Factory | `adf-lcexp-<env>-uks` (system-assigned identity; Azure integration runtime only) |
| TradeBook source | `psql-lcexp-<env>-<rand>`: PostgreSQL 16 Flexible Server, Burstable `B_Standard_B1ms`, database `tradebook`, admin `tradebook_admin` (password in Key Vault `pg-tradebook-password`) |
| Databricks | `dbw-lcexp-<env>-uks` (**Premium**, for Unity Catalog) + access connector `ac-lcexp-<env>` |
| CI/CD SP | `sp-cicd-lcexp` |

Identity and access (Terraform-managed unless noted):

| principal | role | scope |
|---|---|---|
| `sp-cicd-lcexp` ✅ (bootstrap; appId `0e0e7e2d-ecfd-480a-9329-01c0a2a9407e`; OIDC only, trusts `pull_request` + `environment:dev`) | Contributor + Role Based Access Control Administrator | `rg-lcexp-dev-uks` |
| `sp-cicd-lcexp` ✅ (bootstrap) | Storage Blob Data Contributor | TF state storage |
| access connector | Storage Blob Data Contributor; Reader (UC checks it on the storage credential) | ADLS; the access connector itself |
| ADF identity | Storage Blob Data Contributor, Key Vault Secrets User | ADLS, Key Vault |
| whoever runs Terraform (`sp-cicd-lcexp` in CI) | Key Vault Secrets Officer (writes the PostgreSQL password) | Key Vault |

Cost guards: subscription budget alert, cluster auto-termination, `terraform destroy` of dev when idle
(the state RG stays). The PostgreSQL server can be stopped (`az postgres flexible-server stop`);
Azure restarts it after 7 days.

## Repo layout

```
infra/
  modules/        adls, keyvault, adf, postgres, databricks_workspace, unity_catalog, cluster_policy
  envs/{dev,test,prod}/   backend.tf, main.tf, outputs.tf, terraform.tfvars
databricks.yml    Asset Bundle: jobs (Bronze→G2→…→G4); not in Terraform
src/lc_exposure/
  bronze.py       Auto Loader ingest + G2 quarantine
  silver.py       dedupe + MERGE lc_current, reference tables
  gold.py         fact_lc_exposure, agg_group_exposure
  gates.py        G1–G4 rules, audit writer, DQ_GATE_FAILED
adf/              pipeline JSON (Copy → G1 → watermark → Databricks job)
sql/              DDL: TradeBook source tables, audit, Delta tables
tests/            pytest + local Spark fixtures
.github/workflows/terraform.yml
```

## Phases

| # | phase | delivers | done when |
|---|---|---|---|
| 0 | Bootstrap (one-off, by hand with `az`) | state RG + storage + container; `sp-cicd-lcexp` + role assignments + GitHub OIDC federated credentials; repo variables `AZURE_CLIENT_ID` / `AZURE_TENANT_ID` / `AZURE_SUBSCRIPTION_ID`; environment `dev` | a PR's `plan` job passes |
| 1 | Infra | Terraform modules (backend `use_azuread_auth = true`): ADLS, Key Vault, ADF, TradeBook PostgreSQL + ADF linked service, Databricks Premium workspace + access connector, role assignments; Unity Catalog storage credential, external locations, `risk` catalog + `bronze`/`silver`/`gold` schemas; single-node cluster policy | `apply` in dev is clean; second `plan` shows no changes |
| 2 | CI/CD | `terraform.yml`: PR → fmt/validate/plan + PR comment; main → plan → apply → bundle deploy; `main` protected | merge to `main` deploys dev; test/prod need approval |
| 3 | Bronze + G2 | Port Auto Loader job; G2 parse/schema checks, quarantine table | replayed batch adds no lost rows; bad rows quarantined |
| 4 | Silver + G3 | `ROW_NUMBER` dedupe + versioned `MERGE`; reference tables with own validation; G3 key/reference checks | re-running a batch leaves `lc_current` unchanged; missing mapping fails G3 |
| 5 | Gold + G4 | Exposure fact + group/currency aggregate; G4 fact ↔ aggregate reconciliation | Woodgrove fixture yields 9.7m / 97% / no breach |
| 6 | Gate framework | Shared PASS / WARN / FAIL policy, audit table, failure email | a FAIL blocks downstream tasks and writes audit rows |
| 7 | Extraction | Seed TradeBook (schema + sample LCs) and a read-only `adf_reader` role; ADF Copy from PostgreSQL with the watermark JSON in ADLS, manifest, immutable `batch_id` folders; G1 | watermark advances only after G1 passes; retry is safe |
| 8 | Orchestration | ADF parent triggers Databricks job (Bronze→G2→Silver→G3→Gold→G4); Databricks schedule paused | end-to-end run in test; failure email received |
| 9 | Prod | Promote via the `prod` environment's required reviewers; runbook | first prod run reconciles with source counts |

## CI/CD — GitHub Actions

| event | workflow runs | Azure changes |
|---|---|---|
| push to a PR | `plan` job: fmt, validate, `plan` dev; plan posted as a PR comment | none |
| merge to `main` | `apply dev` job (environment `dev`): plan, then `apply` of that plan in the same job | dev |
| (later) after dev | `test`, `prod` jobs on environments with required reviewers | test, prod |

- Auth: OIDC, no client secret exists. azurerm (`ARM_USE_OIDC`) exchanges the GitHub token directly;
  `azure/login` (also OIDC) logs `az` in, and the Databricks provider/CLI use `azure-cli` auth: only it
  sends the ARM management token UC needs to create a storage credential as an SP.
- The SP trusts only `repo:…:pull_request` and `repo:…:environment:dev`. Fork PRs get no OIDC token.
- `main` is protected: PR required, the `plan` check must pass; environment `dev` deploys only from
  protected branches.
- The plan file is never uploaded (it embeds state; artifacts of a public repo are public).
- `concurrency: terraform-dev` runs one workflow at a time and never cancels an apply.
- Test and prod: add `infra/envs/{test,prod}`, environments with required reviewers, and a federated
  credential per environment once the vCPU quota allows a second cluster.
- Databricks code ships as a Databricks Asset Bundle; jobs reference the bundle version.

## Tests

- **Unit**: pure transform functions on small DataFrames (dedupe order, exposure rule, closed LC → 0).
- **Gate**: each G rule has a passing and a failing fixture.
- **Integration (dev)**: replay a sample batch twice; assert idempotent Silver/Gold.

## Out of scope

Hard-delete CDC; cross-table versioned Gold publication (follow-up).
