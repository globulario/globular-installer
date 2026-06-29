# AGENTS.md — Globular Installer Operating Rules

This repository is the Day-0/package installer. It is not a reconciler and it
does not own live cluster truth. It reads YAML package specs, builds a step
plan, applies the plan with idempotent `Check`/`Apply` steps, and writes the
install manifest only after full success.

Reference files:
- `CLAUDE.md`
- `docs/awareness/invariants.yaml`
- `docs/awareness/failure_modes.yaml`
- `docs/awareness/forbidden_fixes.yaml`
- `docs/awareness/authority_rules.yaml`

## Core Model

Do not collapse these states:

1. Desired install state: YAML specs from `--spec` or embedded `internal/specs/*.yaml`
2. Applied install state: `/var/lib/globular/install-manifest.json`
3. Filesystem/systemd state: binaries, configs, units, enabled/running services
4. Runtime health: service-specific health checks after systemd start

Filesystem presence is not proof of successful install. The manifest is written
only after every step succeeds.

## Required Workflow

Before changing installer logic:
1. Identify which state layer the file owns.
2. Read the matching invariant and forbidden fix in `docs/awareness/`.
3. If touching a path in `docs/awareness/high_risk_files.yaml`, run AWG validate/bootstrap checks before commit.
4. Run the affected Go tests. For mutating installer logic, run `go test ./pkg/installer/...`.

## Hard Rules

- Every mutating installer step must preserve the `Check` before `Apply` contract.
- Do not write `install-manifest.json` after partial success.
- Binary replacement must be atomic: temp file in the same directory, then rename.
- Mutating plans must require root; do not add silent user-level fallbacks.
- Never delete `/var/lib/globular`, PKI, etcd, Scylla, or MinIO state unless the operator explicitly requested purge/destructive cleanup.
- After writing or changing a systemd unit, run `daemon-reload` before start or restart.
- Never hardcode numeric UIDs or GIDs. Resolve users/groups by name.
- Do not install network-fetched binaries or executable artifacts without checksum/signature verification.
- Do not treat embedded specs as authoritative when source package specs disagree; run `make check-specs`/`make sync-specs` as appropriate.

## Verification

Use focused checks first:

```bash
go test ./pkg/installer/... -run <relevant-test>
go test ./pkg/platform/... -run <relevant-test>
```

Before reporting complete:

```bash
go test ./...
(cd /tmp/awg-postmerge && go run ./cmd/awg validate -repo-root /tmp/globular-installer-awg -dir /tmp/globular-installer-awg/docs/awareness -ag-repo /tmp/awg-postmerge)
(cd /tmp/awg-postmerge && go run ./cmd/awg bootstrap --repo /tmp/globular-installer-awg -check -skip-history)
```

If `go test ./...` fails on an existing baseline failure, state the exact
failing test and keep the repair scoped.
