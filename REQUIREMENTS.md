# Requirements — LC Exposure by Group (Source → Gold)

Compute letter-of-credit (LC) exposure per counterparty group and currency, from TradeBook
PostgreSQL and reference files, via a Delta Lake medallion pipeline with data-quality gates.

Status: **Implemented** = Bronze, Silver transforms, Gold. **Proposed** = ADF extraction, gate
automation, orchestration, versioned publication.

## 1. Source (proposed)

- **R1.1** Extract LC deals + amendments from TradeBook PostgreSQL incrementally by watermark:
  `updated_at > old AND updated_at <= new`, where `new = max(updated_at)` at extraction start.
- **R1.2** Save the new watermark only after the batch passes G1.
- **R1.3** Extract reference files (counterparty → group mappings, group limits) by modified-time
  window or file manifest.
- **R1.4** Use ADF Copy Activity, with a self-hosted integration runtime (SHIR) for on-prem access.
- **R1.5** Land each batch in a stable path with a manifest, so a retry is safe.

## 2. Landing — ADLS (JSON / Parquet)

- **R2.1** Published batch folders are immutable: `/landing/lc_deals/batch_id=<n>/`.
- **R2.2** `batch_id` identifies a delivery, not an LC revision.
- **R2.3 G1 — extraction completeness**: expected vs copied count, required files, manifest, schema.
  Source and landed counts use the same batch boundary.
- **R2.4** On G1 failure, do not publish the batch and keep the old watermark.

## 3. Bronze — `risk.bronze.lc_deals` (Delta, implemented)

- **R3.1** Append every received version; never drop or overwrite raw data.
- **R3.2** Add provenance columns `src_file`, `ingest_ts`.
- **R3.3** Ingest with Auto Loader (`cloudFiles`), checkpointed, `trigger(availableNow=True)`.
- **R3.4** A new file may replay business records already seen; Bronze keeps them all.
- **R3.5 G2 — parse/schema**: parses, non-null LC key, valid amount and version. Invalid rows are
  quarantined; raw data is preserved.

## 4. Silver (transforms implemented, gate proposed)

- **R4.1** `risk.silver.lc_current`: one current row per `lc_id`; `source_version` comes from source.
- **R4.2** Highest version wins; equal or older versions are ignored. Deduplicate each batch with
  `ROW_NUMBER() OVER (PARTITION BY lc_id ORDER BY source_version DESC)`, then
  `MERGE ... WHEN MATCHED AND s.source_version > t.source_version THEN UPDATE`, `WHEN NOT MATCHED THEN INSERT`.
- **R4.3** `counterparty_group` and `group_limits` are validated, then published to Silver reference
  tables on their own path (not through the LC Bronze parser); used for enrichment and limits.
- **R4.4 G3**: unique LC keys; reference-key uniqueness; no missing mappings/limits; business
  reconciliation. Missing references must be caught before Gold — inner joins silently drop exposure.
- **R4.5** Hard-delete CDC is out of scope (not implemented).

## 5. Gold (implemented)

- **R5.1** `fact_lc_exposure`: one row per LC. `agg_group_exposure`: one row per group + currency.
- **R5.2** Open = `ISSUED`, `ACTIVE`, `AMENDED`. A closed LC stays in the fact with zero exposure.
- **R5.3** `exposure = amount if open else 0`; `gross = SUM(exposure)`; `utilisation = 100 * gross / limit`;
  `headroom = limit − gross`; `breach = gross > limit`.
- **R5.4** Money is decimal; never sum across currencies.
- **R5.5 G4**: fact ↔ aggregate totals agree per currency; limits valid; release only complete outputs.

Example — Woodgrove, USD: LC-2041 v1 2.0m → v2 2.2m, other open LCs 5.0m + 2.5m → gross 9.7m,
limit 10.0m, utilisation 97%, headroom 0.3m, breach No.

## 6. Quality gate policy (proposed)

| result | action |
|---|---|
| PASS | run next task |
| WARN | write audit result, notify; continue if agreed |
| FAIL | persist results, raise exception, block downstream, send failure email |

- **R6.1** `if critical_failures > 0: raise ValueError('DQ_GATE_FAILED')`.
- **R6.2** Audit table: `run_id, batch_id, rule, expected, actual, status, checked_at`.

## 7. Orchestration & recovery (proposed)

- **R7.1** ADF parent: Copy → G1 → commit extraction watermark → run Databricks job.
- **R7.2** Databricks job: Bronze → G2 → Silver → G3 → Gold → G4 → consumers. Each task depends on
  the previous one succeeding.
- **R7.3** One schedule owner: pause the independent Databricks schedule when ADF drives runs.
- **R7.4** Job failure email via `email_notifications.on_failure = var.alert_emails`; recipients must
  be configured.

## 8. CI/CD — Jenkins + Terraform

- **R8.1** Stack: Azure (ADLS Gen2, ADF, Key Vault), Databricks (Unity Catalog, Jobs, Delta),
  Terraform for all infra, Jenkins for all deployments. No manual changes in any environment.
- **R8.2** Environments dev → test → prod, each with its own Terraform state (Azure Storage
  backend, blob-lease locking) and its own service principal.
- **R8.3** Terraform owns: resource groups, ADLS containers, Key Vault, ADF (pipelines, linked
  services, SHIR registration), Databricks workspace, Unity Catalog schemas and grants, clusters,
  jobs (incl. `email_notifications`).
- **R8.4** Jenkins pipeline: lint + unit tests (pytest on PySpark transforms) → `terraform fmt` /
  `validate` → `plan` → manual approval (test, prod) → `apply` → deploy code → smoke run.
- **R8.5** PRs run CI only (tests + `plan`, plan posted for review); merge to `main` promotes.
- **R8.6** Secrets come from Jenkins credentials / Key Vault, never from the repo.
- **R8.7** Releases are tagged; rollback = redeploy the previous tag.

## 9. Recovery semantics

- Watermark = extraction progress; Auto Loader checkpoint = file-processing progress; `MERGE` =
  business-state replay safety.
- Delta ACID is per table; cross-table release consistency needs controlled publication.
- Gold currently overwrites tables separately; versioned publication is a proposed improvement.
