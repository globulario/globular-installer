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
		if err := sm.Start(context.Background(), unit); err != nil {
			if ctx.Logger != nil && ctx.Ports != nil {
				start, end := ctx.Ports.Range()
				ctx.Logger.Infof("start %s failed: port-range=%d-%d reserved=%v", unit, start, end, ctx.Ports.SortedPorts())
			}
			return fmt.Errorf("start %s: %w", unit, err)
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

	id, err := describeServiceID(binPath)
	if err != nil {
		if ctx.Logger != nil {
			ctx.Logger.Infof("start: describe failed for %s; skipping port preflight for %s: %v", binPath, unit, err)
		}
		return nil
	}

	cfgPath := filepath.Join(ctx.ConfigDir, id+".json")
	raw, err := os.ReadFile(cfgPath)
	if err != nil {
		return nil
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

	out, err := json.MarshalIndent(cfg, "", "  ")
	if err != nil {
		return fmt.Errorf("marshal updated config for %s: %w", unit, err)
	}

	spec := platform.FileSpec{
		Path:   cfgPath,
		Data:   append(out, '\n'),
		Owner:  "globular",
		Group:  "globular",
		Mode:   fs.FileMode(0o644),
		Atomic: true,
	}
	if err := ctx.Platform.InstallFiles(context.Background(), []platform.FileSpec{spec}); err != nil {
		return fmt.Errorf("rewrite config %s: %w", cfgPath, err)
	}

	if ctx.Runtime != nil {
		ensureRuntimeMaps(ctx.Runtime)
		ctx.Runtime.ChangedFiles[cfgPath] = true
	}

	if ctx.Logger != nil {
		start, end := ctx.Ports.Range()
		ctx.Logger.Infof("port clash detected for %s: %d in use; rewrote %s to %d (range=%d-%d)", unit, port, cfgPath, newPort, start, end)
	}

	return nil
}

func describeServiceID(binPath string) (string, error) {
	c, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	cmd := exec.CommandContext(c, binPath, "--describe")
	out, err := cmd.Output()
	if err != nil {
		return "", err
	}
	var m map[string]any
	if err := json.Unmarshal(out, &m); err != nil {
		return "", err
	}
	id, _ := m["Id"].(string)
	if id == "" {
		return "", fmt.Errorf("missing Id in --describe")
	}
	return id, nil
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
	if probeListenAddr(fmt.Sprintf("127.0.0.1:%d", port)) {
		return true
	}
	if probeListenAddr(fmt.Sprintf("[::1]:%d", port)) {
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
