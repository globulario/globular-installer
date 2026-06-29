# Installer AWG Manageability Audit

Date: 2026-06-28

Scope:
- Repository: `globular-installer`
- Worktree: `/tmp/globular-installer-awg`
- AWG source: `/tmp/awg-postmerge`

## Extracted Artifacts

AWG bootstrap generated deterministic repository artifacts:
- `docs/awareness/generated/components.yaml`
- `docs/awareness/generated/go_import_graph.yaml`
- `docs/awareness/generated/source_symbols.yaml`
- `docs/awareness/generated/source_edges.yaml`
- `docs/awareness/generated/tests.yaml`
- empty non-Go import graph placeholders for Python, Rust, and TypeScript

Added agent/manageability files:
- `AGENTS.md`
- `docs/awareness/namespaces.yaml`
- `docs/awareness/high_risk_files.yaml`
- `docs/intent/*.yaml` contract docs for the primary installer safety surfaces

## Repairs

- Normalized AWG severity vocabulary from `error` to `high`.
- Added `required_tests` anchors for every critical/high installer invariant.
- Added explicit intent contracts for installer step idempotence, success
  manifest semantics, atomic payload writes, purge safety, spec validation, and
  service config port allocation.
- Synced embedded `internal/specs/*.yaml` with sibling source specs; `make check-specs` now passes.
- Repaired two stale tests:
  - `TestPortAllocatorReservesUniqueAndSkipsInUse` now has enough candidate range for the deliberate occupied port plus three reservations.
  - `TestRbacSpecIncludesPayloadBeforeService` now expects the current `install-rbac-payload` step ID.

## Audit Results

Passing gates:
- `make check-specs`
- `go test ./...`
- `go test ./... -race`
- `go build -buildvcs=false ./...`
- `awg validate -repo-root /tmp/globular-installer-awg -dir /tmp/globular-installer-awg/docs/awareness -ag-repo /tmp/awg-postmerge`
- `awg validate -repo-root /tmp/globular-installer-awg -dir /tmp/globular-installer-awg/docs/awareness -dir /tmp/globular-installer-awg/docs/intent -ag-repo /tmp/awg-postmerge`
- `awg bootstrap --repo /tmp/globular-installer-awg -check -skip-history`
- `awg repo-eval -repo /tmp/globular-installer-awg -ag-repo /tmp/awg-postmerge -services-repo /tmp/services-audit-master`

AWG bootstrap summary:
- components found: 6
- tests found: 59
- source anchors found: 6
- validation findings: 0
- generated freshness: FRESH

Repo-eval posture after intent contracts:
- overall: strong, 97/100, high confidence
- graph integrity: 90/100 (one warning for awareness YAML schemas that are
  intentionally policy metadata rather than imported RDF)
- awareness coverage: 100/100
- invariant/test alignment: 100/100
- contract posture: 100/100 (6 found, 0 proposal-only, 0 unknown)
- architecture drift: 100/100
