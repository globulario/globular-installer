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

## Repairs

- Normalized AWG severity vocabulary from `error` to `high`.
- Added `required_tests` anchors for every critical/high installer invariant.
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
- `awg bootstrap --repo /tmp/globular-installer-awg -check -skip-history`

AWG bootstrap summary:
- components found: 6
- tests found: 59
- source anchors found: 6
- validation findings: 0
- generated freshness: FRESH

Known tool limitation:
- `awg repo-eval` cannot yet evaluate this repository because its target mapper
  accepts services, awareness-graph, or generic repos with a top-level `golang/`
  directory. `globular-installer` is a Go module without that layout.
