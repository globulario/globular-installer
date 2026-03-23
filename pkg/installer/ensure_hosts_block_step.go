package installer

import (
	"fmt"
	"os"
	"strings"

	"github.com/globulario/globular-installer/pkg/net/hostsblock"
)

// EnsureHostsBlockStep manages the /etc/hosts managed block for cluster bootstrap (PR6).
// This step ensures essential control-plane names resolve before DNS service is fully available.
//
// It writes entries for:
//   - controller.<ClusterDomain>
//   - gateway.<ClusterDomain>
//   - <NodeName>.<ClusterDomain>
//
// The managed block is idempotent and atomic. Re-running the installer will not duplicate entries.
type EnsureHostsBlockStep struct {
	// HostsPath is the path to the hosts file (default: /etc/hosts)
	HostsPath string

	// ClusterDomain is the cluster domain suffix (e.g., "cluster.local")
	ClusterDomain string

	// NodeName is the name of this node (e.g., "node-01")
	NodeName string

	// AdvertiseIP is the IP address this node advertises
	AdvertiseIP string

	// ControllerIP is the IP address of the controller (may be same as AdvertiseIP)
	ControllerIP string

	// GatewayIP is the IP address of the gateway (may be same as AdvertiseIP)
	GatewayIP string

	// Enabled controls whether this step should run. Set to false to skip.
	Enabled bool
}

// NewEnsureHostsBlockStep creates a new EnsureHostsBlockStep with default settings.
func NewEnsureHostsBlockStep() *EnsureHostsBlockStep {
	return &EnsureHostsBlockStep{
		HostsPath: "/etc/hosts",
		Enabled:   true,
	}
}

// Name returns the step name for logging.
func (s *EnsureHostsBlockStep) Name() string {
	return "ensure_hosts_block"
}

// Validate checks that required parameters are set.
func (s *EnsureHostsBlockStep) Validate() error {
	if !s.Enabled {
		return nil
	}

	if s.HostsPath == "" {
		return fmt.Errorf("HostsPath must be set")
	}
	if s.ClusterDomain == "" {
		return fmt.Errorf("ClusterDomain must be set")
	}
	if s.NodeName == "" {
		return fmt.Errorf("NodeName must be set")
	}
	if s.AdvertiseIP == "" {
		return fmt.Errorf("AdvertiseIP must be set")
	}

	// Controller and Gateway IPs default to AdvertiseIP if not explicitly set
	if s.ControllerIP == "" {
		s.ControllerIP = s.AdvertiseIP
	}
	if s.GatewayIP == "" {
		s.GatewayIP = s.AdvertiseIP
	}

	return nil
}

// Check verifies if the step needs to be applied.
func (s *EnsureHostsBlockStep) Check(ctx *Context) (StepStatus, error) {
	if !s.Enabled {
		return StatusSkipped, nil
	}

	if err := s.Validate(); err != nil {
		return StatusFailed, fmt.Errorf("validate: %w", err)
	}

	// Check if managed block already exists with correct content
	entries, err := hostsblock.ParseHostsFile(s.HostsPath)
	if err != nil {
		// If we can't read the file, we'll need to apply
		return StatusNeedsApply, nil
	}

	// Check if our entries already exist
	expectedEntries := s.buildEntries()
	for _, expected := range expectedEntries {
		found := false
		for _, existing := range entries {
			if existing.IP == expected.IP {
				// Check if all names match
				allMatch := true
				for _, name := range expected.Names {
					nameFound := false
					for _, existingName := range existing.Names {
						if existingName == name {
							nameFound = true
							break
						}
					}
					if !nameFound {
						allMatch = false
						break
					}
				}
				if allMatch {
					found = true
					break
				}
			}
		}
		if !found {
			return StatusNeedsApply, nil
		}
	}

	return StatusOK, nil
}

// Apply writes the managed block to /etc/hosts.
func (s *EnsureHostsBlockStep) Apply(ctx *Context) error {
	if !s.Enabled {
		ctx.Logger.Debugf("ensure_hosts_block: skipped (disabled)")
		return nil
	}

	if err := s.Validate(); err != nil {
		return fmt.Errorf("validate: %w", err)
	}

	ctx.Logger.Infof("Configuring /etc/hosts managed block for cluster bootstrap")
	ctx.Logger.Debugf("  ClusterDomain: %s", s.ClusterDomain)
	ctx.Logger.Debugf("  NodeName: %s", s.NodeName)
	ctx.Logger.Debugf("  AdvertiseIP: %s", s.AdvertiseIP)

	// Build entries for essential control-plane names
	entries := s.buildEntries()

	// Write managed block
	if err := hostsblock.EnsureManagedBlock(s.HostsPath, s.ClusterDomain, entries); err != nil {
		return fmt.Errorf("write managed block: %w", err)
	}

	ctx.Logger.Infof("Successfully configured /etc/hosts managed block")
	return nil
}

// buildEntries constructs the host entries for this node
func (s *EnsureHostsBlockStep) buildEntries() []hostsblock.HostEntry {
	return []hostsblock.HostEntry{
		{
			IP:    s.ControllerIP,
			Names: []string{fmt.Sprintf("controller.%s", s.ClusterDomain), "controller"},
		},
		{
			IP:    s.GatewayIP,
			Names: []string{fmt.Sprintf("gateway.%s", s.ClusterDomain), "gateway"},
		},
		{
			IP:    s.AdvertiseIP,
			Names: []string{fmt.Sprintf("%s.%s", s.NodeName, s.ClusterDomain), s.NodeName},
		},
	}
}

// RemoveHostsBlockStep removes the managed block from /etc/hosts during uninstall (PR6).
type RemoveHostsBlockStep struct {
	// HostsPath is the path to the hosts file (default: /etc/hosts)
	HostsPath string

	// ClusterDomain is the cluster domain suffix used to identify the block
	ClusterDomain string
}

// NewRemoveHostsBlockStep creates a new RemoveHostsBlockStep with default settings.
func NewRemoveHostsBlockStep() *RemoveHostsBlockStep {
	return &RemoveHostsBlockStep{
		HostsPath: "/etc/hosts",
	}
}

// Name returns the step name for logging.
func (s *RemoveHostsBlockStep) Name() string {
	return "remove_hosts_block"
}

// Validate checks that required parameters are set.
func (s *RemoveHostsBlockStep) Validate() error {
	if s.HostsPath == "" {
		return fmt.Errorf("HostsPath must be set")
	}
	if s.ClusterDomain == "" {
		return fmt.Errorf("ClusterDomain must be set")
	}
	return nil
}

// Check verifies if the managed block needs to be removed.
func (s *RemoveHostsBlockStep) Check(ctx *Context) (StepStatus, error) {
	if err := s.Validate(); err != nil {
		return StatusFailed, fmt.Errorf("validate: %w", err)
	}

	// Check if managed block exists
	content, err := os.ReadFile(s.HostsPath)
	if err != nil {
		// If file doesn't exist or can't be read, nothing to remove
		return StatusOK, nil
	}

	beginMarker := fmt.Sprintf("# BEGIN GLOBULAR MANAGED HOSTS (%s)", s.ClusterDomain)
	if strings.Contains(string(content), beginMarker) {
		return StatusNeedsApply, nil
	}

	return StatusOK, nil
}

// Apply removes the managed block from /etc/hosts.
func (s *RemoveHostsBlockStep) Apply(ctx *Context) error {
	if err := s.Validate(); err != nil {
		return fmt.Errorf("validate: %w", err)
	}

	ctx.Logger.Infof("Removing /etc/hosts managed block")
	ctx.Logger.Debugf("  ClusterDomain: %s", s.ClusterDomain)

	if err := hostsblock.RemoveManagedBlock(s.HostsPath, s.ClusterDomain); err != nil {
		return fmt.Errorf("remove managed block: %w", err)
	}

	ctx.Logger.Infof("Successfully removed /etc/hosts managed block")
	return nil
}
