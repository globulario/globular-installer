package installer

import (
	"bytes"
	"context"
	"fmt"
	"os"
	"path/filepath"

	"github.com/globulario/globular-installer/pkg/platform"
)

type InstallServicesStep struct {
	Units []platform.FileSpec
}

func NewInstallServicesStep() *InstallServicesStep {
	return &InstallServicesStep{}
}

func (s *InstallServicesStep) Name() string {
	return "install-services"
}

func (s *InstallServicesStep) Check(ctx *Context) (StepStatus, error) {
	if ctx == nil {
		return StatusUnknown, fmt.Errorf("nil context")
	}
	if ctx.Platform == nil {
		return StatusUnknown, fmt.Errorf("nil platform")
	}
	files := s.unitsToInstall(ctx)
	if len(files) == 0 {
		return StatusOK, nil
	}
	for _, spec := range files {
		data, err := os.ReadFile(spec.Path)
		if err != nil {
			if os.IsNotExist(err) {
				return StatusNeedsApply, nil
			}
			return StatusUnknown, fmt.Errorf("read %s: %w", spec.Path, err)
		}
		if !bytes.Equal(data, spec.Data) {
			return StatusNeedsApply, nil
		}
	}
	return StatusOK, nil
}

func (s *InstallServicesStep) Apply(ctx *Context) error {
	if ctx == nil {
		return fmt.Errorf("nil context")
	}
	if ctx.Platform == nil {
		return fmt.Errorf("nil platform")
	}

	files := s.unitsToInstall(ctx)
	if len(files) == 0 {
		return nil
	}

	if ctx.DryRun {
		if ctx.Logger != nil {
			ctx.Logger.Infof("dry-run: would install %d service units", len(files))
		}
		return nil
	}

	if installerWithResult, ok := ctx.Platform.(platform.FileInstallerWithResult); ok {
		result, err := installerWithResult.InstallFilesWithResult(context.Background(), files)
		if err != nil {
			return fmt.Errorf("install services: %w", err)
		}
		if ctx.Runtime != nil {
			ensureRuntimeMaps(ctx.Runtime)
		}
		for _, path := range result.Changed {
			if ctx.Runtime != nil {
				ctx.Runtime.ChangedUnits[path] = true
				ctx.Runtime.ChangedUnits[filepath.Base(path)] = true
			}
		}
	} else {
		if err := ctx.Platform.InstallFiles(context.Background(), files); err != nil {
			return fmt.Errorf("install services: %w", err)
		}
		if ctx.Runtime != nil {
			ensureRuntimeMaps(ctx.Runtime)
			for _, spec := range files {
				ctx.Runtime.ChangedUnits[spec.Path] = true
				ctx.Runtime.ChangedUnits[filepath.Base(spec.Path)] = true
			}
		}
	}

	for _, spec := range files {
		data, err := os.ReadFile(spec.Path)
		if err != nil {
			return fmt.Errorf("read installed unit %s: %w", spec.Path, err)
		}
		if bytes.Contains(data, []byte("{{")) {
			return fmt.Errorf("installed unit %s still contains template placeholders", spec.Path)
		}
	}

	sm := ctx.Platform.ServiceManager()
	if sm == nil {
		return fmt.Errorf("service manager unavailable")
	}
	if err := sm.DaemonReload(context.Background()); err != nil {
		return fmt.Errorf("daemon-reload: %w", err)
	}

	return nil
}

func (s *InstallServicesStep) unitsToInstall(ctx *Context) []platform.FileSpec {
	out := make([]platform.FileSpec, len(s.Units))
	for i, u := range s.Units {
		out[i] = u
		out[i].Data = normalizeWorkingDirectory(u.Data)
	}
	return out
}

// normalizeWorkingDirectory rewrites bare WorkingDirectory= lines that
// target /var/lib/globular/ so they use the optional '-' prefix. systemd
// evaluates WorkingDirectory before ExecStartPre, so a missing dir causes
// status=200/CHDIR. The '-' prefix makes it optional.
//
// This must match the node-agent's normalizeUnitWorkingDirectory (in
// golang/systemdutil/working_directory.go) so that the Day-0 installer
// and the reconciler produce identical unit files. A mismatch causes
// permanent unit_file_drift findings.
func normalizeWorkingDirectory(content []byte) []byte {
	const stateRoot = "/var/lib/globular/"
	lines := bytes.Split(content, []byte{'\n'})
	changed := false
	for i, line := range lines {
		trimmed := bytes.TrimLeft(line, " \t")
		if len(trimmed) == 0 || trimmed[0] == '#' || trimmed[0] == ';' {
			continue
		}
		key := []byte("WorkingDirectory=")
		if !bytes.HasPrefix(trimmed, key) {
			continue
		}
		val := bytes.TrimPrefix(trimmed, key)
		if len(val) > 0 && val[0] == '-' {
			continue
		}
		if !bytes.HasPrefix(val, []byte(stateRoot)) {
			continue
		}
		leadLen := len(line) - len(trimmed)
		newLine := make([]byte, 0, leadLen+len("WorkingDirectory=-")+len(val))
		newLine = append(newLine, line[:leadLen]...)
		newLine = append(newLine, []byte("WorkingDirectory=-")...)
		newLine = append(newLine, val...)
		lines[i] = newLine
		changed = true
	}
	if !changed {
		return content
	}
	return bytes.Join(lines, []byte{'\n'})
}

