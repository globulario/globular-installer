package linux

import (
	"bytes"
	"context"
	"fmt"
	"os/exec"
	"strings"

	"github.com/globulario/globular-installer/internal/platform"
)

// SystemdManager uses systemctl to control services.
type SystemdManager struct{}

// NewSystemdManager returns a basic stub that talks to systemctl.
func NewSystemdManager() *SystemdManager {
	return &SystemdManager{}
}

func (m *SystemdManager) run(ctx context.Context, args ...string) (string, string, error) {
	cmd := exec.CommandContext(ctx, "systemctl", args...)
	var outBuf, errBuf bytes.Buffer
	cmd.Stdout = &outBuf
	cmd.Stderr = &errBuf
	err := cmd.Run()
	return outBuf.String(), errBuf.String(), err
}

func systemctlErr(op string, args []string, stderr string, err error) error {
	base := strings.Join(args, " ")
	s := strings.TrimSpace(stderr)
	if s == "" {
		return fmt.Errorf("%s systemctl %s: %w", op, base, err)
	}
	return fmt.Errorf("%s systemctl %s: %s: %w", op, base, s, err)
}

func (m *SystemdManager) DaemonReload(ctx context.Context) error {
	args := []string{"daemon-reload"}
	_, stderr, err := m.run(ctx, args...)
	if err != nil {
		return systemctlErr("daemon-reload", args, stderr, err)
	}
	return nil
}

func (m *SystemdManager) Enable(ctx context.Context, name string) error {
	if err := platform.ValidateServiceName(name); err != nil {
		return err
	}
	args := []string{"enable", name}
	_, stderr, err := m.run(ctx, args...)
	if err != nil {
		return systemctlErr("enable", args, stderr, err)
	}
	return nil
}

func (m *SystemdManager) Disable(ctx context.Context, name string) error {
	if err := platform.ValidateServiceName(name); err != nil {
		return err
	}
	args := []string{"disable", name}
	_, stderr, err := m.run(ctx, args...)
	if err != nil {
		return systemctlErr("disable", args, stderr, err)
	}
	return nil
}

func (m *SystemdManager) Start(ctx context.Context, name string) error {
	if err := platform.ValidateServiceName(name); err != nil {
		return err
	}
	args := []string{"start", name}
	_, stderr, err := m.run(ctx, args...)
	if err != nil {
		return systemctlErr("start", args, stderr, err)
	}
	return nil
}

func (m *SystemdManager) Stop(ctx context.Context, name string) error {
	if err := platform.ValidateServiceName(name); err != nil {
		return err
	}
	args := []string{"stop", name}
	_, stderr, err := m.run(ctx, args...)
	if err != nil {
		return systemctlErr("stop", args, stderr, err)
	}
	return nil
}

func (m *SystemdManager) Restart(ctx context.Context, name string) error {
	if err := platform.ValidateServiceName(name); err != nil {
		return err
	}
	args := []string{"restart", name}
	_, stderr, err := m.run(ctx, args...)
	if err != nil {
		return systemctlErr("restart", args, stderr, err)
	}
	return nil
}

func (m *SystemdManager) Status(ctx context.Context, name string) (platform.ServiceStatus, error) {
	if err := platform.ValidateServiceName(name); err != nil {
		return platform.ServiceStatus{}, err
	}
	args := []string{"show", "-p", "ActiveState", "-p", "SubState", name}
	out, stderr, err := m.run(ctx, args...)
	if err != nil {
		text := strings.ToLower(stderr)
		if strings.Contains(text, "not found") || strings.Contains(text, "could not be found") || strings.Contains(text, "loaded: not-found") {
			return platform.ServiceStatus{Name: name, State: platform.ServiceUnknown, Detail: "not-found"}, nil
		}
		return platform.ServiceStatus{}, systemctlErr("status", args, stderr, err)
	}

	detail := ""
	active := ""
	sub := ""
	for _, line := range strings.Split(out, "\n") {
		line = strings.TrimSpace(line)
		if strings.HasPrefix(line, "ActiveState=") {
			active = strings.TrimPrefix(line, "ActiveState=")
		} else if strings.HasPrefix(line, "SubState=") {
			sub = strings.TrimPrefix(line, "SubState=")
		}
	}

	state := platform.ServiceUnknown
	switch strings.ToLower(active) {
	case "active":
		state = platform.ServiceActive
	case "inactive":
		state = platform.ServiceInactive
	case "failed":
		state = platform.ServiceFailed
	}

	if active != "" {
		detail = active
	}
	if sub != "" {
		detail = fmt.Sprintf("%s (%s)", active, sub)
	}

	return platform.ServiceStatus{Name: name, State: state, Detail: detail}, nil
}

func (m *SystemdManager) IsActive(ctx context.Context, name string) (bool, error) {
	if err := platform.ValidateServiceName(name); err != nil {
		return false, err
	}
	args := []string{"is-active", "--quiet", name}
	_, stderr, err := m.run(ctx, args...)
	if err == nil {
		return true, nil
	}
	if ctx.Err() != nil {
		return false, ctx.Err()
	}
	text := strings.ToLower(stderr)
	if strings.Contains(text, "not found") || strings.Contains(text, "could not be found") {
		return false, nil
	}
	return false, nil
}
