# CLAUDE.md — globular-installer

Day-0 bootstrap CLI. Reads YAML specs, builds a step plan, applies steps
sequentially with Check/Apply idempotency, and writes install-manifest.json
only after every step succeeds. Manages binaries, systemd units, OS users,
/etc/hosts, and directory permissions.

## Build

```bash
go build ./...
go test ./... -race
```

## Key paths

- `cmd/globular-installer/` — CLI entry point
- `pkg/installer/` — SpecPlanBuilder, step types, Check/Apply execution loop
- `pkg/installer/manifest/` — install-manifest.json read/write
- `pkg/installer/spec/` — YAML spec loading and validation
- `pkg/platform/linux/` — systemd, filesystem, users, hostsblock
- `docs/awareness/` — awareness knowledge files (authority rules, invariants, failure modes)

---

## AI RULES — Awareness workflow

This project is registered with the awareness system. The graph lives at
`.globular/awareness/graph.json`. The knowledge files are in `docs/awareness/`.

### Required sequence for any non-trivial edit

1. **`awareness session-start`** — open a session before touching files. Records intent and establishes the edit boundary.
2. **`awareness impact <file>`** — before editing a file, check blast radius. Returns affected invariants, rules, and tests.
3. **`awareness scan-violations`** — after editing, scan for invariant violations before committing.

**`NO_MATCH` ≠ safe.** When awareness returns NO_MATCH (no graph nodes matched), it means the graph has no coverage for that file — not that the edit is safe. Always grep `docs/awareness/failure_modes.yaml`, `docs/awareness/invariants.yaml`, and `docs/awareness/forbidden_fixes.yaml` directly on NO_MATCH.

**`UNKNOWN_IMPACT`** — treat as high-risk. Do not proceed without reading the file and understanding the blast radius manually.

### High-risk files — call `awareness decision_context` before editing

- `pkg/installer/` — any step type; Check/Apply invariant is enforced here
- `pkg/installer/manifest/manifest.go` — manifest write must only happen after full plan success
- `pkg/platform/linux/filesystem.go` — binary replace must be atomic (temp + rename)
- `pkg/platform/linux/systemd.go` — daemon-reload before start/restart is mandatory
- `pkg/platform/linux/users.go` — never hardcode UIDs; always resolve by name
- Any uninstall path — purge of /var/lib/globular requires --purge flag, never implicit

### Awareness token discipline — HARD LIMIT

- **1 preflight per task** — compact (default) unless deep/forensic is justified.
- **Do NOT call `awareness agent_context` in the same turn as `awareness preflight`**.
- **Choose the smallest sufficient mode**: micro → standard → deep → forensic.
- **Never call `awareness session_resume_latest` mid-task** — only at session start if resuming.

### Key invariants enforced

- `installer.check.before.apply` — every step checks desired state before applying; skipping Check breaks idempotency
- `installer.manifest.written.after.full.success` — manifest = record of success; partial manifest is worse than none
- `installer.binary.replace.atomic` — write to temp file in same dir, then rename; never overwrite in place
- `installer.root.required` — RequireRootStep must be first in any mutating plan; no silent fallback
- `installer.purge.explicit.flag.only` — --purge required for /var/lib/globular deletion; never implicit
- `installer.daemon.reload.before.start` — after writing a unit file, daemon-reload before start/restart
- `installer.no.hardcoded.uid` — use user.Lookup("globular"), never a numeric UID
- `installer.fetch.checksum.required` — network-fetched binaries must be SHA-256 verified before use
