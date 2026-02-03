package installer

import (
	"context"
	"encoding/json"
	"fmt"
	"io/fs"
	"net"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
	"time"

	"github.com/globulario/globular-installer/internal/platform"
)

// EnsureServiceConfigStep creates or repairs a service config JSON using the binary's
// --describe output while enforcing the installer port range.
type EnsureServiceConfigStep struct {
	// Required:
	ServiceName string // e.g. "resource" (for logging/ownership)
	Exec        string // e.g. "resource_server"

	// Optional overrides:
	Domain      string // if non-empty, overwrite JSON "Domain"
	AddressHost string // default "localhost"; sets host part of Address
	Owner       string // default "globular"
	Group       string // default "globular"
	Mode        uint32 // default 0644

	// Behavior:
	RewriteIfOutOfRange bool // default true
}

func (s *EnsureServiceConfigStep) Name() string { return "ensure-service-config" }

func (s *EnsureServiceConfigStep) Check(ctx *Context) (StepStatus, error) {
	if ctx == nil {
		return StatusUnknown, fmt.Errorf("nil context")
	}
	if s.Exec == "" {
		return StatusUnknown, fmt.Errorf("missing exec")
	}
	if ctx.Ports == nil {
		return StatusUnknown, fmt.Errorf("ports allocator not initialized")
	}

	desc, err := s.describe(ctx)
	if err != nil {
		return StatusOK, nil // best-effort; don't block
	}

	id, _ := desc["Id"].(string)
	if id == "" {
		return StatusOK, nil
	}

	cfgPath := filepath.Join(ctx.ConfigDir, id+".json")
	b, err := os.ReadFile(cfgPath)
	if err != nil {
		if os.IsNotExist(err) {
			return StatusNeedsApply, nil
		}
		return StatusUnknown, fmt.Errorf("read %s: %w", cfgPath, err)
	}

	if !s.RewriteIfOutOfRange {
		return StatusOK, nil
	}

	var existing map[string]any
	if err := json.Unmarshal(b, &existing); err != nil {
		return StatusNeedsApply, nil
	}
	addr, _ := existing["Address"].(string)
	port, err := parsePort(addr)
	if err != nil {
		return StatusNeedsApply, nil
	}
	start, end := ctx.Ports.Range()
	if port < start || port > end {
		return StatusNeedsApply, nil
	}
	return StatusOK, nil
}

func (s *EnsureServiceConfigStep) Apply(ctx *Context) error {
	if ctx == nil {
		return fmt.Errorf("nil context")
	}
	if ctx.Platform == nil {
		return fmt.Errorf("nil platform")
	}
	if ctx.Ports == nil {
		return fmt.Errorf("ports allocator not initialized")
	}
	if s.Exec == "" {
		return fmt.Errorf("missing exec")
	}

	desc, err := s.describe(ctx)
	if err != nil {
		if ctx.Logger != nil {
			ctx.Logger.Infof("ensure-service-config: describe failed for %s; skipping generation", s.Exec)
		}
		return nil
	}

	id, _ := desc["Id"].(string)
	if id == "" {
		if ctx.Logger != nil {
			ctx.Logger.Infof("ensure-service-config: describe missing Id for %s; skipping generation", s.Exec)
		}
		return nil
	}

	owner := s.Owner
	if owner == "" {
		owner = "globular"
	}
	group := s.Group
	if group == "" {
		group = "globular"
	}
	mode := s.Mode
	if mode == 0 {
		mode = 0o644
	}

	cfgPath := filepath.Join(ctx.ConfigDir, id+".json")
	data, err := os.ReadFile(cfgPath)
	exists := err == nil

	// If config exists and no rewrite needed, just keep it.
	if exists {
		var existing map[string]any
		if err := json.Unmarshal(data, &existing); err == nil {
			if !s.RewriteIfOutOfRange {
				return nil
			}
			if portOKInRange(existing, ctx.Ports) {
				return nil
			}
			if ctx.Ports == nil {
				return nil
			}
			start, end := ctx.Ports.Range()

			candidatePort := extractValidCandidate(desc, start, end)
			newPort, err := ctx.Ports.Reserve(s.ServiceNameOrExec(), candidatePort)
			if err != nil {
				return nil
			}

			host := hostFromAddress(existing["Address"], s.AddressHost)
			existing["Address"] = fmt.Sprintf("%s:%d", host, newPort)
			existing["Port"] = newPort
			if s.Domain != "" {
				existing["Domain"] = s.Domain
			}
			return s.writeConfig(ctx, cfgPath, existing, owner, group, mode)
		}
		// Corrupt existing: leave it alone.
		return nil
	}

	// No existing config: generate from describe if available.
	addr, _ := desc["Address"].(string)
	candidatePort, _ := parsePort(addr)
	port, err := ctx.Ports.Reserve(s.ServiceNameOrExec(), candidatePort)
	if err != nil {
		return nil
	}

	host := s.AddressHost
	if host == "" {
		host = "localhost"
	}
	desc["Address"] = fmt.Sprintf("%s:%d", host, port)
	desc["Port"] = port
	if s.Domain != "" {
		desc["Domain"] = s.Domain
	}

	return s.writeConfig(ctx, cfgPath, desc, owner, group, mode)
}

func (s *EnsureServiceConfigStep) ServiceNameOrExec() string {
	if s.ServiceName != "" {
		return s.ServiceName
	}
	return s.Exec
}

func (s *EnsureServiceConfigStep) describe(ctx *Context) (map[string]any, error) {
	bin := s.Exec
	if !filepath.IsAbs(bin) {
		bin = filepath.Join(ctx.Prefix, "bin", s.Exec)
	}

	c, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	cmd := exec.CommandContext(c, bin, "--describe")
	out, err := cmd.Output()
	if err != nil {
		return nil, fmt.Errorf("describe %s: %w", bin, err)
	}

	var m map[string]any
	if err := json.Unmarshal(out, &m); err != nil {
		return nil, fmt.Errorf("parse describe JSON: %w", err)
	}
	return m, nil
}

func (s *EnsureServiceConfigStep) writeConfig(ctx *Context, cfgPath string, data map[string]any, owner, group string, mode uint32) error {
	out, err := json.MarshalIndent(data, "", "  ")
	if err != nil {
		return fmt.Errorf("marshal config: %w", err)
	}

	spec := platform.FileSpec{
		Path:   cfgPath,
		Data:   append(out, '\n'),
		Owner:  owner,
		Group:  group,
		Mode:   fs.FileMode(mode),
		Atomic: true,
	}

	if ctx.DryRun {
		if ctx.Logger != nil {
			ctx.Logger.Infof("dry-run: would write service config %s", cfgPath)
		}
		return nil
	}

	if err := ctx.Platform.InstallFiles(context.Background(), []platform.FileSpec{spec}); err != nil {
		return fmt.Errorf("install config: %w", err)
	}

	if ctx.Runtime != nil {
		ensureRuntimeMaps(ctx.Runtime)
		ctx.Runtime.ChangedFiles[cfgPath] = true
	}
	return nil
}

func portOKInRange(cfg map[string]any, pa *PortAllocator) bool {
	if pa == nil {
		return true
	}
	addr, _ := cfg["Address"].(string)
	port, err := parsePort(addr)
	if err != nil || port == 0 {
		return false
	}
	start, end := pa.Range()
	return port >= start && port <= end
}

func extractValidCandidate(desc map[string]any, start, end int) int {
	if desc == nil {
		return 0
	}
	addr, _ := desc["Address"].(string)
	if p, err := parsePort(addr); err == nil && p >= start && p <= end {
		return p
	}
	if val, ok := desc["Port"]; ok {
		switch v := val.(type) {
		case int:
			if v >= start && v <= end {
				return v
			}
		case float64:
			pi := int(v)
			if pi >= start && pi <= end {
				return pi
			}
		}
	}
	return 0
}

func hostFromAddress(addrVal any, fallback string) string {
	addr, _ := addrVal.(string)
	if h, _, err := net.SplitHostPort(strings.TrimSpace(addr)); err == nil && h != "" {
		return h
	}
	if idx := strings.LastIndex(addr, ":"); idx > 0 {
		return addr[:idx]
	}
	if fallback != "" {
		return fallback
	}
	return "localhost"
}

func parsePort(address string) (int, error) {
	address = strings.TrimSpace(address)
	if address == "" {
		return 0, fmt.Errorf("empty address")
	}

	if h, p, err := net.SplitHostPort(address); err == nil && h != "" && p != "" {
		pi, err := strconv.Atoi(p)
		if err != nil {
			return 0, err
		}
		return pi, nil
	}

	idx := strings.LastIndex(address, ":")
	if idx < 0 || idx == len(address)-1 {
		return 0, fmt.Errorf("no port in %q", address)
	}
	pi, err := strconv.Atoi(address[idx+1:])
	if err != nil {
		return 0, err
	}
	return pi, nil
}
