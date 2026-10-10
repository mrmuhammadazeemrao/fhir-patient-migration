# Patient and Observation Migration Plan

This plan migrates ~50,000 patients and their Observations from a legacy FHIR R4 API into
a new internal service. Sections 1–5 cover production, and section 6 is the Part 2 slice.

**Assumptions to confirm.** Legacy stays in clinical use, so protecting it matters more
than speed. The new service is empty until cutover, and nothing writes to legacy. Plan for
~600 Observations per patient (~30M rows) until a pilot measures it. Only Observations
whose `subject` is a Patient are in scope.

## 1. Approach

```text
discover patients ─► extract per patient ─► map + validate ─► reconcile ─► delta + cutover
  + manifest         → raw staging          → target          (gate)
```

If the source supports Bulk Data `$export`, use
`Patient/$export?_type=Patient,Observation`. It is one async NDJSON job with a
`transactionTime` cut-off. Otherwise, use throttled REST:

1. **Discover:** page through `Patient?_count=200` by following `Bundle.link` `next`, never computed offsets, because servers may return fewer than `_count`. Store raw Patients and `pending` manifest rows. If the cursor expires (HAPI returns 410), re-run the ~250 idempotent requests.
2. **Extract per patient:** fetch all pages of `Observation?subject=Patient/{id}&_count=200`, then store them and mark the patient `extracted` in one transaction. The patient is the unit of checkpoint, retry and completeness, at the cost of at least one request per patient.
3. **Map** staging into the target separately, so mapper fixes don't touch legacy. Rows are unique on `(source, resource_type, fhir_id)`, and every write is an upsert, so each step is safe to re-run.

**API limits.** One process runs 4 workers that share a rate limiter set to the agreed
rate. It runs off-peak, with 5 s connect and 30 s read timeouts, and makes no network
calls inside DB transactions. The manifest table is the work queue, so no broker is needed.
Estimate: ~150k requests, ~8 h at 5 req/s.

**Failures.** A failed fetch never becomes "no observations".

- **Transient** (timeouts, connection errors, 429, 502/503/504): up to 5 retries with exponential backoff and jitter. Honor `Retry-After`; pause the run beyond 5 min. An expired cursor restarts that patient.
- **Item** (deleted patient, malformed resource, mapping error): mark the patient `failed` and continue.
- **Fatal** (401/403, database down, more than 5% of requests failing over 5 min, or source latency at twice the pilot's): stop, alert, then resume from the manifest.

**Observability.** Progress comes from the `migration_run` row (config, mapping version,
timings) and manifest counts by state. JSON logs carry the run ID, internal key, attempt,
latency and error category. Track throughput, 429 and retry rates, p95 latency and
rejects by reason. A run exits non-zero if reconciliation leaves anything unresolved.

## 2. Data mapping

Mapping functions are pure and versioned, and each returns either a row or a reject with a
reason. Missing values stay null. Nothing is guessed or silently dropped.

- **Patient:** `fhir_id`, `mrn` (identifier type `MR`), `family_name` and `given_names` (the `official` name, else the first, else `text`), `gender`, `deceased`, `source_updated_at`. `birth_date` is stored as text so partial dates like `1980-06` keep their precision.
- **Observation:** `patient_id`, where `subject` must reference this patient (relative, absolute or `_history` form) or the Observation is rejected. Every `status` is kept, `entered-in-error` included, so counts reconcile. Also `category`, `code` (LOINC coding, else first, else `code.text`; all codings kept as JSON), `effective` (original string plus UTC start/end) and `data_absent_reason`.
- **Values:** `value_type` plus the value. Quantity is an exact decimal, never a float (R4 treats `0.010` ≠ `0.01`), with comparator and UCUM unit and no conversion. String, boolean, integer and code are text, where `0` and `false` are values. Range, Ratio, Period and `components` (e.g. blood pressure) are JSON. SampledData and Timing are rejected.

Address, telecom and contacts are not migrated, to minimize data. Other fields can be
added from staging before it expires. Patients with a `replaced-by` link are flagged
for the data owner, never merged.

## 3. Validation (cutover gate)

1. **Load:** mapper checks and database constraints. Every reject carries a reason code.
2. **Completeness:** source Patient IDs must equal target ∪ rejected ∪ documented exclusions, as an exact set diff. Per patient, stored plus rejected Observations must equal fetched. `_summary=count` is only a cross-check, because `Bundle.total` is optional in R4 and the sandbox omits it by default.
3. **Correctness:** diff a fresh source read against the internal API, field by field, for 300 random patients plus edge cases (no observations, components, partial dates). Zero mismatches bounds the per-patient error rate below ~1% at 95% confidence. The sample finds mapping bugs, and step 2 proves completeness.
4. **Sign-off:** a clinical or data owner spot-checks ~20 records. The gate passes when nothing is unexplained and every reject is fixed or accepted.

## 4. PHI safety (real data)

- **Access:** run inside the approved network. The job only reads Patient and Observation, only writes to the target schema, gets secrets from a secret manager, and is run by named, audited operators.
- **Storage:** TLS in transit. The database, staging and backups are encrypted. No copies go on laptops or into tickets, and any vendor handling PHI is under a BAA.
- **Logs:** internal keys, counts and error categories only. Never names, DOB, values, payloads or URLs, because `?subject=Patient/123` exposes IDs and HTTP exceptions embed URLs. PHI-bearing errors stay in the access-controlled rejects table.
- **Retention:** staging and rejects are deleted 30 days after sign-off, which limits the second PHI copy that lets us re-map without reloading legacy. Development uses synthetic data only.

## 5. Rollback

- **Before cutover:** nothing reads the target and legacy is untouched, so stopping is always safe. In-flight transactions roll back, and the manifest shows what finished. Resume, re-map from staging, or truncate the target, which started empty. Legacy is the fallback; no blue/green switch is needed.
- **Cutover:** start a short legacy write freeze and take a delta with `_lastUpdated=gt<run start>` or `$export?_since=`. Deltas may miss deletions, so repeat the ID-set diff and gate, then switch.
- **After cutover:** point consumers back at legacy, which stays readable for an agreed window. Any writes made in the new service would need replaying, so agree the point of no return up front.

## 6. Part 2 slice

Built in ~2 hours on synthetic data to exercise mapping, failures, storage and reads; not a full migration.

- **Scope:** one synchronous `manage.py` command imports one page of `Patient?_count=20`, with up to 100 Observations each. It has no workers, rate limiter, manifest or staging. Pagination is excluded, so a `next` link is logged as truncation and not followed.
- **Failures:** HTTPX timeouts, plus Tenacity retries (3 attempts, backoff with jitter) for timeouts, connection errors, 429 and 5xx. Other 4xx responses fail fast. A failed patient is skipped rather than saved without observations, and the command exits non-zero.
- **Writes:** upsert by `fhir_id`, one transaction per patient, no deletes.
- **Read path:** `GET /api/patients/` and `GET /api/patients/{id}/` (with observations, or 404). The Vue list opens a patient's observations. No auth, pagination or styling.
- **Tests:** mapper edge cases (partial dates, components, `0`/`false`, `dataAbsentReason`, mismatched subject). Retries: 503, 503, then 200 succeeds; 404 is not retried; exhaustion skips the patient and exits non-zero. Re-import is idempotent, and an unknown patient returns 404.

---

Sources: R4 [search](https://hl7.org/fhir/R4/search.html), [Patient](https://hl7.org/fhir/R4/patient.html), [Observation](https://hl7.org/fhir/R4/observation.html), [datatypes](https://hl7.org/fhir/R4/datatypes.html), [references](https://hl7.org/fhir/R4/references.html) and [Bulk Data](https://hl7.org/fhir/uv/bulkdata/STU2/export.html); sandbox checked 2026-10-10.
