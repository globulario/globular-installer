# Globular v1.0 Invariants

This document defines the behavioral contracts that Globular v1.0 MUST NOT violate. These invariants are enforced by the conformance test suite in `tests/conformance/`.

## Purpose

Invariants serve as:
- **Regression prevention**: Automated tests catch violations before deployment
- **Integration boundaries**: Clear contracts for Kubernetes and external systems
- **Operational guarantees**: Predictable behavior across Day-0, Day-1, and Day-N operations

Each invariant specifies:
1. **Statement**: The precise guarantee
2. **Rationale**: Why this invariant exists
3. **Verification**: Command-based steps to validate
4. **Failure Signature**: What users see when violated
5. **Owner**: Which component enforces this (installer, service, both)

---

## Core Invariants

### 1. DNS Service Port Invariant

**Statement**
The DNS service MUST report its actual bound gRPC port in `--describe` metadata output. The reported port MUST match the port on which the service is actually listening.

**Rationale**
The CLI discovery mechanism uses `--describe` to find service endpoints. If the metadata reports a stale or incorrect port (e.g., a hardcoded default that differs from the runtime-allocated port), clients will fail to connect, resulting in timeouts.

**Verification**
```bash
# Get port from service metadata
DESCRIBE_PORT=$(dns_server --describe 2>/dev/null | jq -r '.Port')

# Get actual listening port
ACTUAL_PORT=$(ss -tlnp | grep dns_server | grep -oP ':\K\d+' | head -1)

# Must match
test "$DESCRIBE_PORT" = "$ACTUAL_PORT"
```

**Failure Signature**
```
❌ gRPC Check: FAILED (cannot connect to localhost:10033: context deadline exceeded)
```

User sees connection timeouts when running CLI commands like `globular dns status`. The error message shows the wrong port (e.g., 10033) while the service is actually listening on a different port (e.g., 10006).

**Owner**: Service (DNS server code must initialize metadata with correct port)

**Related Fixes**:
- Commit `019cc4d7` (services): Fixed defaultPort from 10033 to 10006
- Issue: Hardcoded default ports in service binaries conflicting with port allocator assignments

---

### 2. Client Certificate Invariant

**Statement**
User client certificates MUST be generated during Day-0 installation for all users that will interact with the CLI. At minimum, certificates must exist for:
- Root user: `/root/.config/globular/tls/localhost/client.{crt,key}`
- Installing user: `~/.config/globular/tls/localhost/client.{crt,key}`

**Rationale**
All gRPC services require TLS authentication. Without client certificates, the CLI cannot authenticate to services, rendering the system unusable for operational tasks.

**Verification**
```bash
# Check root user certificates
test -f /root/.config/globular/tls/localhost/ca.crt
test -f /root/.config/globular/tls/localhost/client.crt
test -f /root/.config/globular/tls/localhost/client.key
test "$(stat -c %a /root/.config/globular/tls/localhost/client.key)" = "600"

# Check installing user certificates (if not root)
if [[ -n "${SUDO_USER:-}" && "${SUDO_USER}" != "root" ]]; then
  USER_HOME=$(eval echo ~${SUDO_USER})
  test -f "$USER_HOME/.config/globular/tls/localhost/ca.crt"
  test -f "$USER_HOME/.config/globular/tls/localhost/client.crt"
  test -f "$USER_HOME/.config/globular/tls/localhost/client.key"
  test "$(stat -c %a "$USER_HOME/.config/globular/tls/localhost/client.key")" = "600"
fi
```

**Failure Signature**
```
❌ gRPC Check: FAILED (TLS setup error: client certificate not found
   (tried: ~/.config/globular/tls/localhost/client.{crt,key})
Generate certificates with: cd ~/Documents/github.com/globulario/globular-installer &&
   ./scripts/generate-user-client-cert.sh)
```

User must manually run certificate generation script after installation, defeating the purpose of automated Day-0 setup.

**Owner**: Installer (Day-0 script must invoke `generate-user-client-cert.sh` and fail loudly on errors)

**Related Fixes**:
- Commit `de735b6` (installer): Made client cert generation failures fatal
- Issue: Silent failures due to nested sudo, only logged as INFO, installation continued

---

### 3. TLS Certificate Path Compatibility Invariant

**Statement**
Services MUST locate TLS certificate material regardless of naming convention. The system MUST support:
- Traditional naming: `server.crt`, `server.key`, `ca.crt`
- ACME/Let's Encrypt naming: `fullchain.pem`, `privkey.pem`, `ca.pem`
- Generic naming: `cert.pem`, `key.pem`

Services MUST either:
1. Try multiple filenames in priority order (smart discovery), OR
2. Rely on canonical symlinks: `server.crt → fullchain.pem`, `server.key → privkey.pem`, `ca.crt → ca.pem`

**Rationale**
Different provisioning methods (manual setup, ACME, Kubernetes secrets) produce different certificate filenames. Hardcoding a single naming convention breaks integration and manual operations.

**Verification**
```bash
TLS_DIR="/var/lib/globular/config/tls"

# Check canonical files exist
test -f "$TLS_DIR/fullchain.pem"
test -f "$TLS_DIR/privkey.pem"
test -f "$TLS_DIR/ca.pem"

# Check symlinks exist and point to correct targets
test -L "$TLS_DIR/server.crt" && \
  readlink "$TLS_DIR/server.crt" | grep -q "fullchain.pem"

test -L "$TLS_DIR/server.key" && \
  readlink "$TLS_DIR/server.key" | grep -q "privkey.pem"

test -L "$TLS_DIR/ca.crt" && \
  readlink "$TLS_DIR/ca.crt" | grep -q "ca.pem"

# OR verify service code supports multiple names
strings /usr/lib/globular/bin/*_server | grep -E "fullchain|server.crt|cert.pem"
```

**Failure Signature**
```
ERROR: failed to load TLS credentials: cert="" key=""
```

Services fail to start because they cannot locate certificate files, even though valid certificates exist with different names.

**Owner**: Both
- Installer: Must create symlinks during TLS setup (`setup-tls.sh`)
- Service: Should implement smart discovery (`GetTLSFile()` with fallback names)

**Related Fixes**:
- Service `GetTLSFile()` now tries multiple filenames
- `setup-tls.sh` creates required symlinks (belt-and-suspenders approach)

---

### 4. Port 53 Binding Capability Invariant

**Statement**
The DNS service MUST have the capability to bind privileged port 53. This is enforced via:
- Systemd unit: `AmbientCapabilities=CAP_NET_BIND_SERVICE`
- OR binary capability: `setcap cap_net_bind_service=+ep /usr/lib/globular/bin/dns_server`

**Rationale**
Port 53 is a privileged port (<1024) and requires special capabilities when running as a non-root user (globular). Without this capability, the DNS resolver (UDP/TCP port 53) will fail to start, breaking service discovery.

**Verification**
```bash
# Check systemd unit has capability
grep -q "AmbientCapabilities=CAP_NET_BIND_SERVICE" \
  /etc/systemd/system/globular-dns.service

# OR check binary has capability
getcap /usr/lib/globular/bin/dns_server | grep -q cap_net_bind_service

# Verify DNS is actually listening on port 53
ss -tulnp | grep ':53 ' | grep -q dns_server
```

**Failure Signature**
```
bootstrap-dns.sh: Port 53 status: not listening
ERROR: DNS resolver failed to start
```

During Day-0 installation, the DNS bootstrap script detects that port 53 is not listening. The gRPC service may start successfully (on unprivileged port 10006), but the UDP/TCP DNS resolver on port 53 fails.

**Owner**: Both
- Installer: Package spec must include `AmbientCapabilities` in systemd unit (`specgen.sh`)
- Service: Must attempt to bind port 53 and log meaningful errors if it fails

**Related Fixes**:
- Commit (specgen): Added DNS-specific systemd unit generation with `AmbientCapabilities=CAP_NET_BIND_SERVICE`
- `generated/specs/dns_service.yaml` now includes capability in systemd unit

---

## Conformance Testing

All invariants are validated by the conformance test suite:
```bash
cd tests/conformance
./run.sh
```

Tests are designed to:
- Run on a fresh Day-0 installation
- Produce clear pass/fail output
- Print actionable diagnostics on failure
- Execute quickly (< 30 seconds total)

See `tests/conformance/README.md` for details.

---

## Invariant Lifecycle

### Adding New Invariants
1. Document in this file following the template above
2. Add corresponding test in `tests/conformance/`
3. Update `tests/conformance/run.sh` to include new test
4. Ensure existing installations are not broken (compatibility mode if needed)

### Deprecating Invariants
1. Mark as deprecated with end-of-life date
2. Add migration guide
3. Keep test in suite until all supported versions are migrated
4. Remove only after deprecated version is unsupported

---

## Related Documents
- `tests/conformance/README.md` - Conformance test suite documentation
- `docs/k8-integration-boundary.md` - Kubernetes integration contracts (Phase 6)
- `MEMORY.md` - Historical context and known issues
