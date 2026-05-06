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

	"github.com/globulario/globular-installer/pkg/platform"
)

type StartServicesStep struct {
	Services       []string
	RestartOnFiles map[string][]string
	Binaries       map[string]string
}

func NewStartServicesStep() *StartServicesStep {
	return &StartServicesStep{}
}

func (s *StartServicesStep) Name() string {
	return "start-services"
}

func (s *StartServicesStep) Check(ctx *Context) (StepStatus, error) {
	if ctx == nil {
		return StatusUnknown, fmt.Errorf("nil context")
	}
	if ctx.Platform == nil {
		return StatusUnknown, fmt.Errorf("nil platform")
	}
	units := s.serviceList(ctx)
	if len(units) == 0 {
		return StatusUnknown, fmt.Errorf("start-services step requires services list")
	}
	sm := ctx.Platform.ServiceManager()
	if sm == nil {
		return StatusUnknown, fmt.Errorf("service manager unavailable")
	}
	for _, unit := range units {
		active, err := sm.IsActive(context.Background(), unit)
		if err != nil {
			return StatusUnknown, fmt.Errorf("is-active %s: %w", unit, err)
		}
		if !active {
			return StatusNeedsApply, nil
		}
		// A running service whose binary (or unit file) changed must be
		// restarted so it loads the new code. Without this check the runner
		// sees StatusOK and skips Apply() entirely, leaving the old binary
		// running in memory.
		if s.needsRestart(ctx, unit) {
			return StatusNeedsApply, nil
		}
	}
	return StatusOK, nil
}

func (s *StartServicesStep) Apply(ctx *Context) error {
	if ctx == nil {
		return fmt.Errorf("nil context")
	}
	if ctx.Platform == nil {
		return fmt.Errorf("nil platform")
	}

	sm := ctx.Platform.ServiceManager()
	if sm == nil {
		return fmt.Errorf("service manager unavailable")
	}

	units := s.serviceList(ctx)
	for _, unit := range units {
		restartNeeded := s.needsRestart(ctx, unit)
		if ctx.DryRun {
			active, err := sm.IsActive(context.Background(), unit)
			if err != nil {
				return fmt.Errorf("is-active %s: %w", unit, err)
			}
			if ctx.Logger != nil {
				ctx.Logger.Infof("dry-run: would enable %s", unit)

				if active && !restartNeeded {
					ctx.Logger.Infof("dry-run: %s already active; no restart needed", unit)
				} else if active && restartNeeded {
					ctx.Logger.Infof("dry-run: would restart %s", unit)
				} else {
					if bin, ok := s.Binaries[unit]; ok && bin != "" {
						ctx.Logger.Infof("dry-run: would preflight port for %s (bin=%s)", unit, bin)
					}
					ctx.Logger.Infof("dry-run: would start %s", unit)
				}
			}
			continue
		}
		if err := sm.Enable(context.Background(), unit); err != nil {
			return fmt.Errorf("enable %s: %w", unit, err)
		}
		active, err := sm.IsActive(context.Background(), unit)
		if err != nil {
			return fmt.Errorf("is-active %s: %w", unit, err)
		}
		if active && !restartNeeded {
			continue
		}
		if active && restartNeeded {
			if err := sm.Restart(context.Background(), unit); err != nil {
				return fmt.Errorf("restart %s: %w", unit, err)
			}
			continue
		}
		if bin, ok := s.Binaries[unit]; ok && bin != "" {
			if err := startTimeEnsureFreePort(ctx, unit, bin); err != nil {
				return err
			}
		}
		// Clear any prior failed/rate-limited state so systemctl start
		// succeeds even if the service was crash-looping from a previous run.
		sm.ResetFailed(context.Background(), unit)
		if err := sm.Start(context.Background(), unit); err != nil {
			// The initial start can fail transiently (e.g. 203/EXEC race
			// when the binary was just written). Give systemd's
			// Restart=on-failure a chance to recover before giving up.
			recovered := false
			for i := 0; i < 5; i++ {
				time.Sleep(2 * time.Second)
				if active, aerr := sm.IsActive(context.Background(), unit); aerr == nil && active {
					recovered = true
					if ctx.Logger != nil {
						ctx.Logger.Infof("start %s: recovered after transient failure (attempt %d)", unit, i+1)
					}
					break
				}
			}
			if !recovered {
				if ctx.Logger != nil && ctx.Ports != nil {
					start, end := ctx.Ports.Range()
					ctx.Logger.Infof("start %s failed: port-range=%d-%d reserved=%v", unit, start, end, ctx.Ports.SortedPorts())
				}
				return fmt.Errorf("start %s: %w", unit, err)
			}
		}
	}

	return nil
}

func (s *StartServicesStep) serviceList(ctx *Context) []string {
	return s.Services
}

func prefixedBinaryPath(ctx *Context, name string) string {
	return filepath.Join(ctx.Prefix, "bin", name)
}

func (s *StartServicesStep) needsRestart(ctx *Context, unit string) bool {
	if ctx == nil || ctx.Runtime == nil {
		return false
	}
	if ctx.Runtime.ChangedUnits[unitPath(unit)] {
		return true
	}
	if ctx.Runtime.ChangedUnits[unit] {
		return true
	}
	for _, file := range s.RestartOnFiles[unit] {
		if ctx.Runtime.ChangedFiles[file] {
			return true
		}
	}
	if bin, ok := s.Binaries[unit]; ok && bin != "" {
		if ctx.Runtime.ChangedBinaries[prefixedBinaryPath(ctx, bin)] {
			return true
		}
	}
	return false
}

func unitPath(unit string) string {
	return filepath.Join("/etc/systemd/system", unit)
}

var portProbe = isTCPPortInUse

func startTimeEnsureFreePort(ctx *Context, unit string, binName string) error {
	if ctx == nil || ctx.Platform == nil {
		return fmt.Errorf("nil context/platform")
	}
	if ctx.Ports == nil {
		return nil
	}

	binPath := binName
	if !filepath.IsAbs(binPath) {
		binPath = filepath.Join(ctx.Prefix, "bin", binName)
	}

	desc, err := describeService(binPath)
	if err != nil {
		if ctx.Logger != nil {
			ctx.Logger.Infof("start: describe failed for %s; skipping port preflight for %s: %v", binPath, unit, err)
		}
		return nil
	}
	id := desc["Id"].(string)

	cfgPath := filepath.Join(ctx.ConfigDir, id+".json")
	raw, err := os.ReadFile(cfgPath)
	if err != nil {
		// First install — no config yet. Seed it with a pre-allocated free port so
		// the service starts without a runtime port conflict.
		return writeSeedConfig(ctx, unit, cfgPath, desc)
	}

	var cfg map[string]any
	if err := json.Unmarshal(raw, &cfg); err != nil {
		return nil
	}

	addr, _ := cfg["Address"].(string)
	port, err := parsePortForStart(addr)
	if err != nil || port == 0 {
		return nil
	}

	if !portProbe(port) {
		return nil
	}

	newPort, err := ctx.Ports.Reserve(unit)
	if err != nil {
		return fmt.Errorf("port %d in use for %s, no alternative: %w", port, unit, err)
	}

	host := "localhost"
	if h, _, e := net.SplitHostPort(strings.TrimSpace(addr)); e == nil && h != "" {
		host = h
	} else if idx := strings.LastIndex(addr, ":"); idx > 0 {
		host = addr[:idx]
	}

	cfg["Address"] = fmt.Sprintf("%s:%d", host, newPort)
	cfg["Port"] = newPort

	if err := writeConfigFile(ctx, cfgPath, cfg); err != nil {
		return err
	}

	if ctx.Logger != nil {
		start, end := ctx.Ports.Range()
		ctx.Logger.Infof("port clash detected for %s: %d in use; rewrote %s to %d (range=%d-%d)", unit, port, cfgPath, newPort, start, end)
	}
	return nil
}

// writeSeedConfig creates a minimal service config from --describe output with a
// pre-checked free port. This runs on first install before systemd starts the service.
func writeSeedConfig(ctx *Context, unit, cfgPath string, desc map[string]any) error {
	// Determine default port: prefer "DefaultPort" field, fall back to "Port".
	defaultPort := descInt(desc, "DefaultPort")
	if defaultPort == 0 {
		defaultPort = descInt(desc, "Port")
	}
	if defaultPort == 0 {
		return nil // Can't determine port; let service handle it at runtime.
	}

	// Determine host from describe address (may be "localhost:N" or just "localhost").
	host := "localhost"
	if addr, _ := desc["Address"].(string); addr != "" {
		if h, _, e := net.SplitHostPort(strings.TrimSpace(addr)); e == nil && h != "" {
			host = h
		} else if idx := strings.LastIndex(addr, ":"); idx > 0 {
			host = addr[:idx]
		} else {
			host = addr
		}
	}

	// Choose the final port: default if free, otherwise reserve an alternative.
	port := defaultPort
	if portProbe(port) && ctx.Ports != nil {
		newPort, err := ctx.Ports.Reserve(unit)
		if err != nil {
			if ctx.Logger != nil {
				ctx.Logger.Infof("seed-config: port %d in use for %s, no alternative (%v); service will self-heal", defaultPort, unit, err)
			}
		} else {
			port = newPort
		}
	}

	// Build seed config: start from describe output so all fields are present,
	// then override address/port with the chosen free port.
	seed := make(map[string]any, len(desc))
	for k, v := range desc {
		seed[k] = v
	}
	seed["Address"] = fmt.Sprintf("%s:%d", host, port)
	seed["Port"] = port
	delete(seed, "DefaultPort") // runtime-only hint, not stored in config
	delete(seed, "PortRange")   // runtime-only hint, not stored in config

	if err := writeConfigFile(ctx, cfgPath, seed); err != nil {
		return err
	}

	if ctx.Logger != nil {
		ctx.Logger.Infof("seed-config: wrote initial config for %s at %s (port=%d)", unit, cfgPath, port)
	}
	return nil
}

// writeConfigFile atomically writes cfg as JSON to path using the platform installer.
func writeConfigFile(ctx *Context, path string, cfg map[string]any) error {
	out, err := json.MarshalIndent(cfg, "", "  ")
	if err != nil {
		return fmt.Errorf("marshal config for %s: %w", path, err)
	}

	spec := platform.FileSpec{
		Path:   path,
		Data:   append(out, '\n'),
		Owner:  "globular",
		Group:  "globular",
		Mode:   fs.FileMode(0o644),
		Atomic: true,
	}
	if err := ctx.Platform.InstallFiles(context.Background(), []platform.FileSpec{spec}); err != nil {
		return fmt.Errorf("write config %s: %w", path, err)
	}

	if ctx.Runtime != nil {
		ensureRuntimeMaps(ctx.Runtime)
		ctx.Runtime.ChangedFiles[path] = true
	}

	return nil
}

// descInt extracts an integer from a describe map field (handles float64 from JSON).
func descInt(m map[string]any, key string) int {
	v := m[key]
	switch n := v.(type) {
	case int:
		return n
	case float64:
		return int(n)
	case int64:
		return int(n)
	}
	return 0
}

// describeService runs binary --describe and returns the full describe map.
// The map is guaranteed to have a non-empty "Id" field on success.
func describeService(binPath string) (map[string]any, error) {
	c, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	cmd := exec.CommandContext(c, binPath, "--describe")
	out, err := cmd.Output()
	if err != nil {
		return nil, err
	}
	var m map[string]any
	if err := json.Unmarshal(out, &m); err != nil {
		return nil, err
	}
	id, _ := m["Id"].(string)
	if id == "" {
		return nil, fmt.Errorf("missing Id in --describe")
	}
	return m, nil
}

// describeServiceID is a convenience wrapper that returns just the service Id.
func describeServiceID(binPath string) (string, error) {
	m, err := describeService(binPath)
	if err != nil {
		return "", err
	}
	return m["Id"].(string), nil
}

func parsePortForStart(address string) (int, error) {
	address = strings.TrimSpace(address)
	if address == "" {
		return 0, fmt.Errorf("empty")
	}
	if _, p, err := net.SplitHostPort(address); err == nil {
		return strconv.Atoi(p)
	}
	idx := strings.LastIndex(address, ":")
	if idx < 0 || idx == len(address)-1 {
		return 0, fmt.Errorf("no port in %q", address)
	}
	return strconv.Atoi(address[idx+1:])
}

func isTCPPortInUse(port int) bool {
	// Wildcard bind catches listeners on ANY interface (e.g. 10.0.0.63:PORT).
	if probeListenAddr(fmt.Sprintf("0.0.0.0:%d", port)) {
		return true
	}
	if probeListenAddr(fmt.Sprintf("[::]:%d", port)) {
		return true
	}
	// Also probe loopback explicitly — on some kernels a loopback-only
	// listener doesn't block a wildcard bind attempt.
	if probeListenAddr(fmt.Sprintf("127.0.0.1:%d", port)) {
		return true
	}
	return false
}

func probeListenAddr(addr string) bool {
	l, err := net.Listen("tcp", addr)
	if err != nil {
		s := strings.ToLower(err.Error())
		if strings.Contains(s, "address already in use") {
			return true
		}
		return false
	}
	_ = l.Close()
	return false
}
