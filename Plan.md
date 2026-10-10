# Patient and Observation Migration Plan

Migrate approximately 50,000 FHIR R4 patients and their observations into an internal service, keeping the source read-only. Part 2 demonstrates a bounded synthetic sample from `https://hapi.fhir.org/baseR4` using Django, PostgreSQL, and Vue.

## 1. Overall approach

**Establish a consistent source.** Confirm searches, rate limits, volume, and migration window with the source owner. Use a consistent export or arrange a write freeze for REST extraction. A timestamp filter alone cannot preserve overwritten/deleted versions. Record the source, extraction window, and mapping version. Without consistency, report drift and reconcile before cutover.

**Extract, map, stage, validate, publish.** Use a restartable batch command outside web requests. Start with patient pages of 100; query `/Observation?subject=Patient/{id}` per patient. Follow `Bundle.link[relation=next]` for both resource types, processing one page at a time; `_count` limits page size, not total results. Persist a patient manifest with pending/completed/failed states and observation counts, saving discovery progress alongside manifest entries. If a cursor expires, restart discovery and deduplicate against the manifest.

**Control load and failures.** Start with two concurrent requests and a shared configurable rate cap agreed with the source owner. Reuse connections; set 5-second connect/30-second read timeouts. Allow four attempts for connection failures, timeouts, HTTP 429, and transient 5xx responses, with exponential backoff and jitter. Honor `Retry-After`; pause if it exceeds the retry budget. Stop for authentication/configuration errors, database outages, or sustained source failures. Invalid responses and missing/malformed resources are explicit failures, never empty results.

**Make retries safe.** Stage each run separately, with unique `(run_id, source_system, resource_type, fhir_id)` keys; never merge people by name. Commit bounded database batches after network calls. Mark a patient complete only after its patient row and all observation pages are validated and saved. Retry failed patients without duplicates; never infer deletion from incomplete fetches.

**Observe progress.** Record discovered/completed/failed patients, fetched/saved/rejected observations, retries, latency, and duration. Finish with a reconciliation report and nonzero exit status for unresolved failures. Log run IDs, counts, and error categories; restrict resource IDs and failure details.

## 2. Data mapping

Patient and Observation have internal IDs, a patient foreign key, source identity, run provenance, and `meta.versionId`/`meta.lastUpdated` when present.

| Resource | Internal fields and rules |
| --- | --- |
| Patient | `fhir_id`; display name from first official name, otherwise first usable name, joining all given names and family (text fallback); nullable gender; birth date as validated ISO text preserving year/month/day precision. Missing demographics remain missing. |
| Observation | `fhir_id`; patient foreign key from `subject.reference`; status; coding system/code pairs and label (`code.text` fallback); typed value; units; effective time; components; absence reason. Resolve relative or same-source absolute patient references; reject unresolved/mismatched subjects. |

Use normalized JSON for typed values and component results such as blood pressure. Preserve quantities as decimal text with comparator and unit/system/code; do not convert clinical units. Distinguish strings, integers, booleans, and coded values: zero and false are valid. Preserve effective date precision and period boundaries; retain `dataAbsentReason` for absent values. Unsupported variants and clinically significant modifiers require review and block completion, rather than silently becoming null. Store selected fields, not full FHIR payloads.

## 3. Validation and acceptance

- Check resource types, IDs, mapped fields, uniqueness, and patient relationships. No observations is valid; an observation-fetch failure is not equivalent.
- Reconcile the stable source manifest against staged patient IDs and distinct observation IDs/counts per patient. Every resource must be saved or have a documented failure. `Bundle.total`, when confirmed accurate, is a cross-check, not proof of completeness. Publish with no unresolved failures or unexplained differences.
- Compare 100 randomly selected patients and their observations against the same extraction: demographics, codes, units, statuses, missing values, and components.
- Test partial dates, zero/false values, retry exhaustion, failed observation fetches, and duplicate-free reruns. Verify API/UI detail data and empty/error states.

## 4. Safety

Use synthetic data throughout the exercise. For real PHI: authorized read-only source access, least-privilege destination access, TLS, encrypted storage/backups, managed secrets, and audited operator access. Keep PHI, raw identifiers, payloads, search URLs, and upstream error bodies out of ordinary logs, Git, and AI tools. Minimize storage and define staging/failure retention. Production access controls are outside the exercise implementation.

## 5. Rollback and recovery

Keep candidate runs separate from the active dataset. On failure, stop scheduling, roll back unfinished transactions, preserve checkpoints, and retry incomplete patients after repair. Readers retain the previous dataset. After validation, atomically switch an active-run pointer; rollback switches it back. Retain the previous dataset through acceptance. For an initial load, hide the candidate. Discard failed staging after diagnosis. Run tags cannot restore overwritten rows; isolated candidates avoid overwrites.

## 6. Part 2 boundary

Build a management command importing a small synthetic patient sample, persistence, `GET /api/patients/`, and `GET /api/patients/{id}/` with observations. Vue lists patients and opens their observations. Bound source responses and explicitly report truncation; do not claim a complete migration. Full traversal, manifests, and staged cutover belong to the scale plan. Exclude authentication, deployment, styling polish, real-time sync, and pagination features. Include meaningful backend tests, README instructions, AI-use notes, and limitations within the roughly three-hour budget.

FHIR details checked against official R4 [search](https://hl7.org/fhir/R4/search.html), [Patient](https://hl7.org/fhir/R4/patient.html), [Observation](https://hl7.org/fhir/R4/observation.html), and [data types](https://hl7.org/fhir/R4/datatypes.html).
