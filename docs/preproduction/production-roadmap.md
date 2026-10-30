# WorldForge production roadmap

**Status:** Planning draft from the exact base below. This document does not declare pre-production complete or any unverified criterion PASS.
**Base:** `seth1295/world_forge`, `codex/wf-gate-d-adjacent-consumer`, `4a23601a4cacb20db1eb752cb03574dd6c76803c`.
**Product scope:** Standalone Earth-wide geographic game foundation. Regional technical slices are evidence, not a reduced product scope.
**Phase boundary:** Complete and review Gate E exit evidence before production is declared started. Gameplay is a separate later workstream.

## 1. Evidence and open status at the base

The ledger records a real USGS 3DEP-to-WorldForge generator-to-Godot path for Baltimore and Golden. Gate C was QA-approved and merged. Gate D source-identity commit `5ad6487d7fc78f3b8972544d998e8b81731da3cd` and adjacent tile/LOD commit `41cb237d0aa75d86386cdc7595d7bad5037cabb3` are recorded on local branches, with independent QA review pending. Their logs report 137/137 focused adjacent checks and 232/232 full checks; this roadmap did not rerun them or inspect a new capture. The base records LOD 0 source-sampled collision and disabled LOD 1 collision for the Golden pair; its 13.497314453 m omitted-sample deviation is crop-specific structural evidence, not source accuracy or an accepted ground-contact limit. The independent generator path is demonstrated, while broader inherited BeamNG server/service coupling remains open.

The terrain artifacts retain NAD83/GRS80 regional charts and NAVD88 heights. The separate WGS 84 ellipsoid utility has numeric tests, but no NAD83 realization/epoch or NAVD88-to-global operation connects USGS terrain to it. There is no global tile index, engine-wide origin manager, persistent object registry, simulation state service, or save/migration service. The Windows handoff reports a root-certificate-store diagnostic during local-file runs; those runs do not establish remote HTTPS source access. The USGS pilot sources have local prototype provenance/rights records, not worldwide source, inherited-asset, imagery, vector-data, or commercial redistribution clearance.

The separate foundations proposal from the same base is a draft companion artifact, not part of this patch or the exact-base tree. It proposes global-position, object identity/lifecycle, tick, and snapshot contracts; it still needs independent review. **No overall WF-EXIT criterion is marked PASS here.**

## 2. WF-EXIT status and closure evidence

- **WF-EXIT-01 - Correct scope:** WorldForge's standalone Earth-wide direction and repository boundaries are documented. Final independent review must confirm no production BeamNG runtime dependency and preserve the three-repository separation.
- **WF-EXIT-02 - Inherited baseline:** Baseline ledger and risk register record actual sources, pins, gaps, and known coupling. QA must confirm evidence matches the exact component revisions and relevant licence issues.
- **WF-EXIT-03 - Real independent producer:** The register reports merged WorldForge producer changes and 9/9 hardening tests against two real outputs. Reproduce the producer/consumer contract on the exact pins and Windows; broader BeamNG-coupled legacy paths remain tracked.
- **WF-EXIT-04 - Real Godot consumer:** Gate C's actual Windows build/render/capture is recorded as QA-approved on its merged revision. Reproduce or independently verify the current integration head, both regions, actual generator output, ground-level capture, and start/shutdown behavior. Gate D additions still need review.
- **WF-EXIT-05 - Planetary feasibility:** Regional projections and WGS 84 numeric tests are evidence only for their stated domains. Choose and justify global CRS/realization/epoch and vertical-operation policy; test independent references across separated regions and relevant pole, antimeridian, large-coordinate, and height cases. Main Lead sets scenario-specific accuracy limits from uncertainty and reference evidence. Full-Earth content coverage remains a production task.
- **WF-EXIT-06 - Streaming feasibility:** The base records one adjacent Golden pair, crop-specific LOD, stale-result rejection, unload, and collision behavior. Independently review the exact Gate D head and test failure/cancel/retry, repeated travel, readiness, collision eligibility and rebase behavior beyond that pair. Global tile selection and engine-wide origin management remain unproven.
- **WF-EXIT-07 - Future game foundations:** Risk R8 says entity/state/persistence interfaces are absent. Review and validate the companion position, identity/lifecycle, tick, snapshot, and migration boundaries at production-planning depth. If contract tests do not establish lifecycle invariants, add a minimal non-gameplay Godot fixture. No gameplay is required.
- **WF-EXIT-08 - Windows reproducibility:** Windows build and local-data evidence exist, but the certificate-store diagnostic and remote data path remain unresolved. Reproduce commands, dependencies, builds and data access on Windows without disabling TLS verification.
- **WF-EXIT-09 - Rights/provenance:** The register reports review of the two USGS products. QA must verify their records and keep inherited assets and future global/vector/image sources as separate rights questions. No worldwide rights clearance is implied.
- **WF-EXIT-10 - Independent QA:** Gate C review is complete; Gate D review is pending. QA Lead must consolidate exact-head findings and confirm no unresolved P0/P1 issue affects the exit claim.
- **WF-EXIT-11 - Production readiness:** Risk and architecture records exist; this is a draft roadmap. The Gate E handoff must link tested decisions, limitations, rights, risks, exact commands, and executable production work packages.

## 3. Ordered pre-production closeout

The packages below are prerequisites to an honest Gate E decision. Acceptance is functional and evidence-based; elapsed time, frame rate, throughput, or hardware-efficiency limits are not pre-production gates.

### PP-1 - Independently review exact Gate D changes

**Depends on:** exact local Gate D source-identity and adjacent-consumer revisions.

QA Lead reviews source allowlisting, the Golden adjacent pair, seam identity, LOD transition, collision eligibility, stale results, and unload/resource lifecycle on the exact head. Engineering fixes blocking findings and reruns affected checks.

**Acceptance evidence:** independent QA verdict names the exact revision; focused source-identity/adjacent suites and full consumer suite run using the pinned Windows Godot build. Retain commands, exit codes, logs, and reproducible runtime/capture context. Existing logs alone do not review a changed head.

### PP-2 - Resolve Windows data access and source provenance

**Depends on:** PP-1's verified test path.

Reproduce the approved USGS source acquisition/replay path on Windows. Diagnose the root-certificate-store error. Preserve immutable source/sidecar/product hashes, CRS and vertical meaning, uncertainty, acquisition record, attribution, terms, and acquisition command. Keep code licences separate from data rights.

**Acceptance evidence:** a clean task-local run accesses an approved official endpoint with verified TLS and produces a hash-matched snapshot, or records a precise BLOCKED cause and reproducible approved offline-input route. Explain the certificate result or state its unresolved scope. Never disable TLS verification or substitute an unverified source. QA audits the data records.

### PP-3 - Establish global frame and accuracy policy

**Depends on:** PP-2's verified input semantics and the Main Lead's prototype-source policy.

Specify the WorldForge global CRS, realization/epoch, axes/units, vertical reference, and allowed named/versioned transformation operations. Fail closed where no defensible operation exists. Main Lead sets scenario-specific correctness/error limits from source uncertainty and independent references; do not invent one universal number.

**Acceptance evidence:** independent forward/inverse reference tests at separated regions and applicable latitude, antimeridian, large-coordinate, and height extremes; negative tests reject unresolved or incompatible frames. Report numerical round-trip error, source uncertainty, and geometry alignment separately. If NAD83/NAVD88 cannot be bridged defensibly, leave it unavailable and disposition the criterion explicitly.

### PP-4 - Specify and exercise planetary tile/LOD/collision lifecycle

**Depends on:** PP-3's frame and operation policy.

Define a versioned planetary tile key, separate from data-content revision, LOD, object identity, and engine-local origin. Specify neighbor ownership, seams, cache invalidation, cancellation, failure recovery, readiness, and collision eligibility.

**Acceptance evidence:** actual-build functional tests cover adjacent real tiles and shared boundaries; atomic LOD transitions; reload/revisit; stale completion; cancellation/failure/retry; shutdown; and applicable high-latitude, antimeridian, or polar fixtures. Collision follows the currently eligible terrain; a visual coarse LOD is never presumed contact-ready. Use justified seam/omission criteria, not performance limits.

### PP-5 - Check one or more feature layers for interoperability

**Depends on:** PP-2 provenance and PP-3/PP-4 coordinate and tile contracts.

Select representative available roads, buildings, water, land cover, or vegetation only from a source whose actual terms permit the intended prototype use. Define engine-neutral feature IDs, geometry/attributes, CRS/datum, vertical meaning, source version, and alignment behavior. This is a representative slice, not global feature completeness.

**Acceptance evidence:** with a permitted, versioned source, validate terrain/tile/LOD/origin alignment and retain source uncertainty, attribution, and terms. If suitable data are unavailable, label the layer BLOCKED/NOT VERIFIED and record the fallback; do not use unclear data to make the demo look complete.

### PP-6 - Validate future simulation/state foundations

**Depends on:** PP-3 global position and PP-4 streaming ownership.

Review the companion proposal for frame-declared global positions, stable namespaced object IDs/revisions, transient stream-binding generations, unload distinct from tombstone, integer tick and command ordering, versioned state snapshots, component schemas, and deterministic migration policy. Reuse Godot scene/node/physics facilities; add no gameplay or speculative ECS.

**Acceptance evidence:** contract tests reject missing coordinate identity, duplicate/dangling IDs, stale bindings and unsupported schema versions. QA confirms the interfaces and tests are sufficient for production planning. If they are not, add a small non-gameplay Godot fixture proving identity survives unload/reload and origin rebasing. A production save service is future implementation work.

### PP-7 - Assemble and independently assess Gate E handoff

**Depends on:** PP-1 through PP-6.

Reproduce the independent generator -> WorldForge contract -> pinned Godot flow using two geographically separated real regions. The handoff must contain the system architecture and decisions; exact commits and Windows build/launch/data/capture procedure; verification matrix; source/code rights and provenance; risk/feasibility conclusions; this production roadmap; and the QA Lead's independent assessment.

**Acceptance evidence:** QA independently reproduces or inspects the exact build, real-data flow, coordinate placement, ground-level capture, streaming tests, and provenance. Every WF-EXIT status is recorded as PASS/FAIL/BLOCKED/NOT RUN with exact revision and evidence. List unresolved P0/P1 findings. The Main Lead declares pre-production complete only when every exit condition is supported; closing this document is not sufficient.

**Producer update:** Generator head 325cd2c now validates each bundle payload from one bounded, SHA-checked byte buffer for numeric and seam checks, and tests post-close mutation, malformed metadata, and post-build rollback. Engineering reports 16/16 Windows real-data tests. The earlier R10 payload-reread and seam-rollback advisories are addressed in that code, but independent QA of 325 is still pending. Source TIFF/XML mutation during generation and cleanup-removal failure are not claimed as covered; retain immutable source snapshots and a bounded acquisition process before broad ingestion.

## 4. Dependency-ordered production work packages

These packages start after Gate E's verified decision; they are not claims of current completion. Keep generator, engine, and parent integration separate and pin compatible revisions.

### P-1 - Earth-wide spatial reference and source catalog

**Depends on:** PP-3 and PP-7. Finalize the global frame/operation registry, source fallback rules, scenario accuracy records, coverage requirements, and rights/provenance catalog. Main Lead retains ownership of spatial limits and source policy.

**Acceptance:** independent reference and uncertainty tests for each supported domain; audit every data/asset version, attribution, database/media term, use, and redistribution right. Unknown transforms or rights fail closed.

### P-2 - Global acquisition and independent generation

**Depends on:** P-1. Extend WorldForge-native acquisition/validation/generation across Earth-wide land and applicable coastal, bathymetric, and polar regions using lawful sources. Preserve per-source fidelity and coverage variation; never imply uniform accuracy.

**Acceptance:** reproducible source-to-contract outputs from separated and edge-case regions, including outage, corruption, no-data, and fallback tests; source identity, datum, uncertainty, and provenance verify end to end. Record actual coverage gaps.

### P-3 - Versioned planetary tile index, cache, and LOD selection

**Depends on:** P-1 and P-2. Implement global tile addressing across the antimeridian and poles, stable geographic keys, separate content revisions, neighbor rules, cache invalidation, and an evidence-based LOD policy.

**Acceptance:** multi-neighbor tests prove stable identity through LOD/reload, no missing/duplicate boundary geometry, coherent seam positions, stale-cache rejection, and correct transitions under movement/altitude changes. Use scenario-specific geometry limits.

### P-4 - Terrain streaming, origin management, and collision

**Depends on:** P-3 and demonstrated Godot needs. Use existing engine facilities; change the engine only after a reproducible acceptance failure proves a missing capability. Implement async lifecycle, cancellation/replacement, origin rebasing, readiness, and resource release.

**Acceptance:** actual pinned-build tests cover repeated travel, replacement, cancellation/failure, rebase, seams/LOD, collision readiness/alignment, startup/shutdown, and stale work after tile/object revision changes.

### P-5 - Feature-layer contracts and integration

**Depends on:** P-1 and P-3. Add legally usable roads, structures, water, land cover, vegetation, or other chosen layers through versioned engine-neutral contracts with source identity, vertical semantics, uncertainty, and classification.

**Acceptance:** cross-layer tests verify terrain/tile seam, LOD, origin-shift, and source-revision alignment. Reject stale features, unapproved coordinate frames, and missing provenance. Track progressive geographic coverage and unimplemented layers.

### P-6 - Runtime simulation and persistence foundations

**Depends on:** reviewed WF-EXIT-07 interface and P-1/P-3/P-4. Implement the minimal Godot-native object registry, global positions, object revisions, stream bindings, deterministic tick/command order, snapshots, component/schema migrations, tombstones, and recovery. No gameplay is part of this package.

**Acceptance:** actual-runtime tests prove one ID/state survives create, tile move, rebase, unload/reload, LOD replacement, and shutdown; stale completion cannot resurrect it. Test pause/resume tick semantics, snapshot round-trip, vN->vN+1 migration, unsupported future/corrupt state, interrupted atomic write, and recovery from the prior snapshot.

### P-7 - Integrated Earth-world validation

**Depends on:** P-2 through P-6. Expand verified regions and technical traversal to expose data, geodesy, streaming, feature alignment, and state continuity across the world.

**Acceptance:** reproducible actual-build sessions in widely separated and edge-case regions; QA verifies transforms, provenance, terrain/features/collision, stream failure/recovery, and save/reload. Coverage and rights gaps remain explicit.

### P-8 - Gameplay, after separate scope definition

The established initial direction is third-person foot movement (walk/run/jump), driving, pedestrians, and road traffic. Flying details remain unresolved; police are not required for the initial baseline. Build gameplay only after its scope and acceptance tests are separately defined and world foundations support it. Do not infer additional systems.

### Deferred - Production efficiency and platform tuning

Define performance, efficiency, and platform targets in a later production plan after correctness, coverage, lifecycle, and target-platform needs are stable. They are not pre-production QA metrics, PR blockers, or mission exit criteria.

## 5. Cross-package rules

- Keep Earth-wide coverage as the destination; staged data availability is a risk, not a reason to design a regional-only product.
- Attach CRS, realization/epoch, axes, units, vertical datum, operation provenance, and uncertainty to coordinates and source data. Main Lead owns scenario-specific accuracy limits.
- Keep tile geography, tile content revision, LOD, object identity, and local origin separate. Seams, duplicates, readiness, collision, cancellation, and cleanup are correctness requirements.
- Preserve required upstream code notices and audit code licences separately from terrain, imagery, vector/database, and other asset rights. Public download does not establish redistribution or commercial rights.
- Reproduce on Windows with pinned revisions, exact commands, data hashes, environment dependencies, and artifacts. Mark unavailable work NOT RUN/BLOCKED.
- Keep architecture decisions, demonstrator steps, verification matrix, provenance, risk, roadmap, and QA assessment together in the Gate E handoff.
- Do not use performance or efficiency targets as a pre-production gate. Keep gameplay and production feature completeness in later work.

## Current Gate E local checkpoint (2026-10-30)

The sections above are a planning draft authored against parent consumer base 4a23601. Since that base, the local integration branch `codex/gate-e-preproduction-handoff` has cherry-picked the roads proof through `4f8cdd8` and applied the simulation-foundations contract and this roadmap. It stages generator gitlink `325cd2c` while preserving the pinned Godot revision `d733911`. The accompanying [planetary spatial and LOD design](planetary-spatial-design.md) records the tested local-frame decisions and global limits. The source-identity and adjacent consumer implementation heads remain `5ad6487` and `4a23601` respectively; all four checked-in terrain manifests now identify generator head `325cd2c4048bc9cf19a2287afc4de51c145f4490` with recorded-receipt provenance. Their artifact IDs and XY/height payload hashes match the earlier `fc9ff8a` artifacts; `.gitattributes` preserves exact manifest bytes on Windows.

Main Lead reran the Windows component suites on the local combined snapshot: generator 16/16 with verified USGS inputs and all four payloads matched; roads 14/14 Python with the Census archive; foundations 10/10 structural checks; pinned Godot import exit 0, terrain 232/232, adjacent 137/137, and roads PASS. Godot still logs the root-certificate-store diagnostic, which remote HTTPS was not tested to resolve. Independent QA of the final exact heads and a consolidated exit review remain incomplete because the previous QA Lead hit its Luna usage limit; earlier approvals remain bound to their exact SHAs. No new parent PR or push exists; the overall mission remains incomplete.
