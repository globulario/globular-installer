# PR6: /etc/hosts Managed Block for Cluster Bootstrap

## Overview

PR6 implements a managed block in `/etc/hosts` to ensure essential control-plane names resolve before the DNS service is fully available. This solves the egg/chicken problem during Day0 installation in cluster mode.

## Features

- **Idempotent**: Re-running the installer will not duplicate entries
- **Atomic**: Uses atomic file writes (write to temp, fsync, rename)
- **Safe**: Preserves file permissions and ownership
- **Clean uninstall**: Removes only the managed block, leaving other entries intact
- **Multiple clusters**: Supports multiple managed blocks (one per cluster domain)

## Managed Block Format

The managed block is surrounded by explicit markers:

```
# BEGIN GLOBULAR MANAGED HOSTS (cluster.local)
10.0.1.100 controller.cluster.local controller
10.0.1.100 gateway.cluster.local gateway
10.0.1.101 node-01.cluster.local node-01
# END GLOBULAR MANAGED HOSTS (cluster.local)
```

## Installation Step Usage

### In Install Spec

Add the `ensure_hosts_block` step after node identity is known:

```yaml
steps:
  - id: ensure-user
    type: ensure_user_group
    params:
      user: globular
      group: globular

  - id: ensure-dirs
    type: ensure_dirs

  # ... other steps ...

  # Add after node identity is determined
  - id: bootstrap-hosts
    type: ensure_hosts_block
    params:
      cluster_domain: "{{.ClusterDomain}}"      # e.g., "cluster.local"
      node_name: "{{.NodeName}}"                # e.g., "node-01"
      advertise_ip: "{{.AdvertiseIP}}"          # e.g., "10.0.1.101"
      controller_ip: "{{.ControllerIP}}"        # Optional, defaults to advertise_ip
      gateway_ip: "{{.GatewayIP}}"              # Optional, defaults to advertise_ip
      hosts_path: "/etc/hosts"                  # Optional, default: /etc/hosts
      enabled: true                             # Optional, default: true

  # ... continue with start_services, etc. ...
```

### Programmatic Usage

```go
import (
    "github.com/globulario/globular-installer/internal/installer"
)

// During Day0 installation
step := installer.NewEnsureHostsBlockStep()
step.ClusterDomain = "cluster.local"
step.NodeName = "node-01"
step.AdvertiseIP = "10.0.1.101"
step.ControllerIP = "10.0.1.100" // Optional
step.GatewayIP = "10.0.1.100"    // Optional

if err := step.Execute(ctx); err != nil {
    return fmt.Errorf("bootstrap hosts: %w", err)
}
```

### Uninstall Step

Add the `remove_hosts_block` step during uninstall:

```yaml
steps:
  - id: remove-hosts
    type: remove_hosts_block
    params:
      cluster_domain: "{{.ClusterDomain}}"
      hosts_path: "/etc/hosts"
```

Or programmatically:

```go
step := installer.NewRemoveHostsBlockStep()
step.ClusterDomain = "cluster.local"

if err := step.Execute(ctx); err != nil {
    return fmt.Errorf("remove hosts block: %w", err)
}
```

## What Gets Added

The installer adds **only essential control-plane names**:

1. **controller.\<clusterDomain\>** → Points to controller node IP
2. **gateway.\<clusterDomain\>** → Points to gateway node IP
3. **\<nodeName\>.\<clusterDomain\>** → Points to this node's advertise IP

**Per-service FQDNs are NOT added** to /etc/hosts. Services resolve via DNS once the DNS service starts.

## Example: Single-Node Cluster

For a single-node cluster where the same machine runs controller, gateway, and services:

```yaml
- id: bootstrap-hosts
  type: ensure_hosts_block
  params:
    cluster_domain: "cluster.local"
    node_name: "node-01"
    advertise_ip: "10.0.1.100"
    # controller_ip and gateway_ip will default to advertise_ip
```

Result in `/etc/hosts`:

```
# BEGIN GLOBULAR MANAGED HOSTS (cluster.local)
10.0.1.100 controller.cluster.local controller
10.0.1.100 gateway.cluster.local gateway
10.0.1.100 node-01.cluster.local node-01
# END GLOBULAR MANAGED HOSTS (cluster.local)
```

## Example: Multi-Node Cluster

For a multi-node cluster with dedicated controller and gateway:

**On controller node (10.0.1.100):**
```yaml
- id: bootstrap-hosts
  type: ensure_hosts_block
  params:
    cluster_domain: "cluster.local"
    node_name: "controller"
    advertise_ip: "10.0.1.100"
    controller_ip: "10.0.1.100"
    gateway_ip: "10.0.1.100"
```

**On worker node (10.0.1.101):**
```yaml
- id: bootstrap-hosts
  type: ensure_hosts_block
  params:
    cluster_domain: "cluster.local"
    node_name: "node-01"
    advertise_ip: "10.0.1.101"
    controller_ip: "10.0.1.100"
    gateway_ip: "10.0.1.100"
```

## Integration with Template Variables

The installer supports template variables. Common patterns:

```yaml
params:
  cluster_domain: "{{.Spec.ClusterDomain}}"
  node_name: "{{.Spec.NodeName}}"
  advertise_ip: "{{.Spec.AdvertiseIP}}"
  controller_ip: "{{.Spec.ControllerIP}}"
  gateway_ip: "{{.Spec.GatewayIP}}"
```

These variables should be populated from cluster configuration during installation planning.

## Safety Guarantees

1. **Atomic writes**: File is never left in a partially-written state
2. **Permission preservation**: File permissions and ownership are preserved
3. **Idempotent**: Running twice produces identical results
4. **No duplicates**: Validates entries have no duplicate hostnames
5. **Graceful handling**: Handles files without trailing newlines
6. **Clean removal**: Uninstall removes only the managed block

## Testing

The hostsblock package includes comprehensive tests:

```bash
cd internal/net/hostsblock
go test -v
```

Tests cover:
- New block creation
- Block replacement (update)
- Idempotency
- Files without trailing newlines
- Duplicate name detection
- Block removal
- Permission preservation
- Multiple concurrent blocks

## Limitations

1. **Linux-only**: Designed for `/etc/hosts` on Linux systems
2. **No service FQDNs**: Does not manage per-service FQDNs (use DNS for those)
3. **Static entries**: Entries are static; updates require re-running the step
4. **Single domain per block**: Each managed block is for one cluster domain

## Migration from Manual Entries

If you previously managed `/etc/hosts` entries manually:

1. The managed block will **not remove** existing entries outside the block
2. You can safely migrate by:
   - Running the installer with `ensure_hosts_block`
   - Manually removing duplicate entries outside the managed block
   - Subsequent installations will maintain only the managed block

## Troubleshooting

### "duplicate hostname" error

**Cause**: Entries contain duplicate hostnames within the managed block.

**Solution**: Ensure each hostname appears only once in the configuration.

### Block not created

**Cause**: Missing required parameters (cluster_domain, node_name, advertise_ip).

**Solution**: Verify all required parameters are set in the spec.

### Permission denied

**Cause**: Installer does not have write access to `/etc/hosts`.

**Solution**: Run installer with appropriate privileges (usually requires root).

### Block not removed during uninstall

**Cause**: ClusterDomain parameter doesn't match the original installation.

**Solution**: Use the same cluster_domain value that was used during installation.

## See Also

- PR4: DNS-first naming and gateway routing
- PR4.1: SRV records for service discovery
- PR7: DNS high availability (multi-DNS nodes)
