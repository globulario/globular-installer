package installer

import (
	"context"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"time"
)

// RunScriptStep executes a shell script from the package's scripts/ directory.
// It behaves like a deb postinst: the script is discovered from the staging
// area and executed with well-known environment variables.
type RunScriptStep struct {
	Script  string        // script filename (default "post-install.sh")
	Timeout time.Duration // execution timeout (default 5m)
	applied bool
}

func NewRunScriptStep(script string, timeout time.Duration) *RunScriptStep {
	if script == "" {
		script = "post-install.sh"
	}
	if timeout <= 0 {
		timeout = 5 * time.Minute
	}
	return &RunScriptStep{Script: script, Timeout: timeout}
}

func (s *RunScriptStep) Name() string {
	return fmt.Sprintf("run-script[%s]", s.Script)
}

func (s *RunScriptStep) Check(ctx *Context) (StepStatus, error) {
	if s.applied {
		return StatusOK, nil
	}
	scriptPath := s.resolveScript(ctx)
	if scriptPath == "" {
		return StatusSkipped, nil
	}
	return StatusNeedsApply, nil
}

func (s *RunScriptStep) Apply(ctx *Context) error {
	scriptPath := s.resolveScript(ctx)
	if scriptPath == "" {
		return nil
	}

	if err := os.Chmod(scriptPath, 0755); err != nil {
		return fmt.Errorf("chmod script %s: %w", scriptPath, err)
	}

	if ctx.DryRun {
		if ctx.Logger != nil {
			ctx.Logger.Infof("[dry-run] would execute %s", scriptPath)
		}
		s.applied = true
		return nil
	}

	nodeIP := "127.0.0.1"
	if ip, ok := ctx.TemplateVars["NodeIP"]; ok && ip != "" {
		nodeIP = ip
	}

	// Determine component name from the staged package manifest.
	componentName := ""
	componentVersion := ""
	if ctx.Runtime != nil {
		componentName = ctx.Runtime.StagedPackageName
		componentVersion = ctx.Runtime.StagedPackageVersion
	}

	timeout, cancel := context.WithTimeout(context.Background(), s.Timeout)
	defer cancel()

	cmd := exec.CommandContext(timeout, "/bin/bash", scriptPath)
	cmd.Env = append(os.Environ(),
		"COMPONENT_NAME="+componentName,
		"COMPONENT_VERSION="+componentVersion,
		"STATE_DIR="+ctx.StateDir,
		"PREFIX="+ctx.Prefix,
		"CONFIG_DIR="+ctx.ConfigDir,
		"NODE_IP="+nodeIP,
	)
	cmd.Dir = filepath.Dir(scriptPath)

	output, err := cmd.CombinedOutput()
	if ctx.Logger != nil && len(output) > 0 {
		ctx.Logger.Infof("[%s] %s", s.Script, string(output))
	}
	if err != nil {
		return fmt.Errorf("script %s failed: %w", s.Script, err)
	}

	s.applied = true
	return nil
}

// resolveScript looks for the script in the staging directory's scripts/ subdirectory.
func (s *RunScriptStep) resolveScript(ctx *Context) string {
	if ctx.StagingDir == "" {
		return ""
	}
	candidate := filepath.Join(ctx.StagingDir, "scripts", s.Script)
	if info, err := os.Stat(candidate); err == nil && !info.IsDir() {
		return candidate
	}
	return ""
}
