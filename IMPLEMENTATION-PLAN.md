# Implementation Plan — LC Exposure by Group

Delivers [REQUIREMENTS.md](REQUIREMENTS.md). Stack: Azure, Databricks, Terraform, Jenkins.

## Target environment

| item | value |
|---|---|
| Subscription | `5cd3e971-2e20-49fb-95bc-021190718075` (Azure subscription 1, Default Directory) |
| Tenant | `9a1807cc-1918-4a95-ad1e-17b6555bba94`; you are Owner + Global Administrator |
| Region | `uksouth` |
| Quota | 4 vCPUs regional → one single-node `Standard_DS3_v2` cluster, 15 min auto-terminate; jobs run one at a time |
| Jenkins | local, `brew services` `jenkins-lts` on `http://localhost:8080`, Java 21 |

Names (one `env` suffix each; dev only until quota is raised):

| resource | name |
|---|---|
| TF state ✅ | `rg-tfstate-uks` (delete lock) / `sttfstate8014mr` (Entra auth only, versioning, 30-day soft delete) / container `tfstate`, key `lcexp-<env>.tfstate` |
| Resource group ✅ | `rg-lcexp-<env>-uks`, created in bootstrap; Terraform reads it (`data`), never creates it |
| ADLS Gen2 | `stlcexp<env><rand>`: containers `landing`, `bronze`, `silver`, `gold`, `checkpoints`, `catalog` (UC catalog root) |
| Key Vault | `kv-lcexp-<env>-<rand>` (RBAC mode) |
| Data Factory | `adf-lcexp-<env>-uks` (system-assigned identity) |
| Databricks | `dbw-lcexp-<env>-uks` (**Premium**, for Unity Catalog) + access connector `ac-lcexp-<env>` |
| Jenkins SP | `sp-jenkins-lcexp` |

Identity and access (Terraform-managed unless noted):

| principal | role | scope |
|---|---|---|
| `sp-jenkins-lcexp` ✅ (bootstrap; appId `0e0e7e2d-ecfd-480a-9329-01c0a2a9407e`, secret expires 2027-11) | Contributor + Role Based Access Control Administrator | `rg-lcexp-dev-uks` |
| `sp-jenkins-lcexp` ✅ (bootstrap) | Storage Blob Data Contributor | TF state storage |
| access connector | Storage Blob Data Contributor | ADLS |
| ADF identity | Storage Blob Data Contributor, Key Vault Secrets User | ADLS, Key Vault |

Cost guards: subscription budget alert, cluster auto-termination, `terraform destroy` of dev when idle
(the state RG stays).

## Repo layout

```
infra/
  modules/        adls, keyvault, adf, databricks_workspace, unity_catalog, cluster_policy
  envs/{dev,test,prod}/   backend.tf, main.tf, outputs.tf, terraform.tfvars
databricks.yml    Asset Bundle: jobs (Bronze→G2→…→G4); not in Terraform
src/lc_exposure/
  bronze.py       Auto Loader ingest + G2 quarantine
  silver.py       dedupe + MERGE lc_current, reference tables
  gold.py         fact_lc_exposure, agg_group_exposure
  gates.py        G1–G4 rules, audit writer, DQ_GATE_FAILED
adf/              pipeline JSON (Copy → G1 → watermark → Databricks job)
sql/              DDL: watermark, audit, Delta tables
tests/            pytest + local Spark fixtures
Jenkinsfile
```

## Phases

| # | phase | delivers | done when |
|---|---|---|---|
| 0 | Bootstrap (one-off, by hand with `az`) | state RG + storage + container; `sp-jenkins-lcexp` + role assignments; Jenkins credentials `azure-sp-lcexp` (client id/secret, tenant, subscription); plugins: Pipeline, Git, Credentials Binding, AnsiColor | `terraform plan` runs from Jenkins for dev |
| 1 | Infra | Terraform modules (backend `use_azuread_auth = true`): ADLS, Key Vault, ADF, Databricks Premium workspace + access connector, role assignments; Unity Catalog storage credential, external locations, `risk` catalog + `bronze`/`silver`/`gold` schemas; single-node cluster policy | `apply` in dev is clean; second `plan` shows no changes |
| 2 | CI/CD | `Jenkinsfile`: test → fmt/validate → plan → approval → apply → bundle deploy → smoke run | merge to `main` deploys dev; test/prod need approval |
| 3 | Bronze + G2 | Port Auto Loader job; G2 parse/schema checks, quarantine table | replayed batch adds no lost rows; bad rows quarantined |
| 4 | Silver + G3 | `ROW_NUMBER` dedupe + versioned `MERGE`; reference tables with own validation; G3 key/reference checks | re-running a batch leaves `lc_current` unchanged; missing mapping fails G3 |
| 5 | Gold + G4 | Exposure fact + group/currency aggregate; G4 fact ↔ aggregate reconciliation | Woodgrove fixture yields 9.7m / 97% / no breach |
| 6 | Gate framework | Shared PASS / WARN / FAIL policy, audit table, failure email | a FAIL blocks downstream tasks and writes audit rows |
| 7 | Extraction | ADF Copy (SHIR) with watermark table, manifest, immutable `batch_id` folders; G1 | watermark advances only after G1 passes; retry is safe |
| 8 | Orchestration | ADF parent triggers Databricks job (Bronze→G2→Silver→G3→Gold→G4); Databricks schedule paused | end-to-end run in test; failure email received |
| 9 | Prod | Promote via Jenkins with approval; runbook | first prod run reconciles with source counts |

## Jenkins pipeline

```
Checkout → Lint + pytest → terraform fmt/validate
  → plan (dev) → apply (dev) → databricks bundle deploy (dev) → smoke job
  → [approve] → plan/apply/deploy (test)
  → [approve] → plan/apply/deploy (prod)
```

| event | Jenkins runs | Azure changes |
|---|---|---|
| push to a PR | tests, fmt/validate, `plan` dev (artifact `plan-dev.txt`) | none |
| merge to `main` | same, then `apply` of that saved plan, bundle deploy | dev |
| (later) after dev | `plan` test → `input` approval → `apply`; same for prod | test, prod |

- Job type: **Multibranch Pipeline**, GitHub branch source, discovers `main` + PRs; fork PRs not built
  (they would run Terraform with the SP's credentials).
- Trigger: GitHub webhook → Jenkins (via a relay while Jenkins is on localhost); periodic scan as fallback.
- `main` is protected: PR required, Jenkins status check must pass, no direct pushes.
- Credentials: Jenkins credential `azure-sp-lcexp`, injected as `ARM_CLIENT_ID`, `ARM_CLIENT_SECRET`,
  `ARM_TENANT_ID`, `ARM_SUBSCRIPTION_ID`; the Databricks provider and CLI authenticate with the same SP.
- Agent: the local Jenkins node; `terraform`, `databricks`, `az`, Python 3 must be on Jenkins' `PATH`
  (Homebrew `/opt/homebrew/bin`).
- Test and prod stages exist in the `Jenkinsfile` but stay disabled until the vCPU quota allows a
  second workspace's cluster.
- Databricks code ships as a Databricks Asset Bundle; jobs reference the bundle version.

## Tests

- **Unit**: pure transform functions on small DataFrames (dedupe order, exposure rule, closed LC → 0).
- **Gate**: each G rule has a passing and a failing fixture.
- **Integration (dev)**: replay a sample batch twice; assert idempotent Silver/Gold.

## Out of scope

Hard-delete CDC; cross-table versioned Gold publication (follow-up).
