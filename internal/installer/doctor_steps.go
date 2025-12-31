package installer

import (
	"fmt"
	"os"
	"os/exec"
	"strings"
)

type RequireRootStep struct{}

func NewRequireRootStep() *RequireRootStep {
	return &RequireRootStep{}
}

func (s *RequireRootStep) Name() string {
	return "require-root"
}

func (s *RequireRootStep) Check(ctx *Context) (StepStatus, error) {
	if ctx == nil {
		return StatusUnknown, fmt.Errorf("nil context")
	}
	if ctx.DryRun {
		return StatusOK, nil
	}
	if os.Geteuid() != 0 {
		return StatusFailed, fmt.Errorf("must run as root (try: sudo globular-installer ...)")
	}
	return StatusOK, nil
}

func (s *RequireRootStep) Apply(ctx *Context) error {
	_, err := s.Check(ctx)
	return err
}

type CheckSystemdStep struct{}

func NewCheckSystemdStep() *CheckSystemdStep {
	return &CheckSystemdStep{}
}

func (s *CheckSystemdStep) Name() string {
	return "check-systemd"
}

func (s *CheckSystemdStep) Check(ctx *Context) (StepStatus, error) {
	if ctx == nil {
		return StatusUnknown, fmt.Errorf("nil context")
	}
	if _, err := exec.LookPath("systemctl"); err != nil {
		return StatusFailed, fmt.Errorf("systemctl not found in PATH (systemd is required on Linux)")
	}

	cmd := exec.Command("systemctl", "is-system-running")
	out, err := cmd.CombinedOutput()
	result := strings.TrimSpace(string(out))

	if err != nil {
		if result == "degraded" {
			return StatusOK, nil
		}
		if result == "" {
			return StatusFailed, fmt.Errorf("systemctl failed; systemd may not be running or accessible")
		}
		return StatusFailed, fmt.Errorf("systemd not ready: %s", result)
	}

	switch result {
	case "running", "degraded", "starting":
		return StatusOK, nil
	default:
		return StatusFailed, fmt.Errorf("systemd state is %q (expected running/degraded starting)", result)
	}
}

func (s *CheckSystemdStep) Apply(ctx *Context) error {
	_, err := s.Check(ctx)
	return err
}

type CheckCommandsStep struct {
	Required []string
}

func NewCheckCommandsStep(required []string) *CheckCommandsStep {
	if len(required) == 0 {
		required = []string{"systemctl", "getent", "groupadd", "useradd", "usermod"}
	}
	return &CheckCommandsStep{Required: required}
}

func (s *CheckCommandsStep) Name() string {
	return "check-commands"
}

func (s *CheckCommandsStep) Check(ctx *Context) (StepStatus, error) {
	if ctx == nil {
		return StatusUnknown, fmt.Errorf("nil context")
	}
	missing := make([]string, 0)
	for _, cmd := range s.Required {
		cmd = strings.TrimSpace(cmd)
		if cmd == "" {
			continue
		}
		if _, err := exec.LookPath(cmd); err != nil {
			missing = append(missing, cmd)
		}
	}
	if len(missing) > 0 {
		return StatusFailed, fmt.Errorf("missing required commands in PATH: %s", strings.Join(missing, ", "))
	}
	return StatusOK, nil
}

func (s *CheckCommandsStep) Apply(ctx *Context) error {
	_, err := s.Check(ctx)
	return err
}
