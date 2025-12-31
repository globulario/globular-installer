package installer

import (
	"context"
	"fmt"
	"os"
	"path/filepath"

	"github.com/globulario/globular-installer/internal/platform"
)

type InstallServicesStep struct{}

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
	return StatusNeedsApply, nil
}

func (s *InstallServicesStep) Apply(ctx *Context) error {
	if ctx == nil {
		return fmt.Errorf("nil context")
	}
	if ctx.Platform == nil {
		return fmt.Errorf("nil platform")
	}

	files := buildUnitFiles(ctx)
	if len(files) == 0 {
		return nil
	}

	if ctx.DryRun {
		if ctx.Logger != nil {
			ctx.Logger.Infof("dry-run: would install %d service units", len(files))
		}
		return nil
	}

	changedCount := 0
	if installer, ok := ctx.Platform.(platform.FileInstallerWithResult); ok {
		result, err := installer.InstallFilesWithResult(context.Background(), files)
		if err != nil {
			return fmt.Errorf("install services: %w", err)
		}
		for _, path := range result.Changed {
			if ctx.Runtime != nil {
				ctx.Runtime.ChangedUnits[path] = true
			}
		}
		changedCount = len(result.Changed)
	} else {
		if err := ctx.Platform.InstallFiles(context.Background(), files); err != nil {
			return fmt.Errorf("install services: %w", err)
		}
		changedCount = len(files)
		if ctx.Runtime != nil {
			for _, file := range files {
				ctx.Runtime.ChangedUnits[file.Path] = true
			}
		}
	}

	sm := ctx.Platform.ServiceManager()
	if sm == nil {
		return fmt.Errorf("service manager unavailable")
	}
	if changedCount > 0 {
		if err := sm.DaemonReload(context.Background()); err != nil {
			return fmt.Errorf("daemon-reload: %w", err)
		}
	} else if ctx.Logger != nil {
		ctx.Logger.Infof("install-services: no unit changes; skipping daemon-reload")
	}

	return nil
}

func buildUnitFiles(ctx *Context) []platform.FileSpec {
	out := make([]platform.FileSpec, 0, len(enabledServices(ctx)))
	for _, unit := range enabledServices(ctx) {
		desc := unitDescription(unit)
		unitPath := filepath.Join("/etc/systemd/system", unit)
		data := []byte(unitTemplatePlaceholder(desc))
		switch unit {
		case "globular-gateway.service":
			path := prefixedBinaryPath(ctx, "gateway")
			if fileExists(path) {
				data = []byte(unitTemplateReal(desc, path, ctx.StateDir))
			}
		case "globular-xds.service":
			path := prefixedBinaryPath(ctx, "xds")
			if fileExists(path) {
				data = []byte(unitTemplateReal(desc, path, ctx.StateDir))
			}
		}
		out = append(out, platform.FileSpec{
			Path:   unitPath,
			Data:   data,
			Owner:  "root",
			Group:  "root",
			Mode:   0o644,
			Atomic: true,
		})
	}
	return out
}

func unitTemplatePlaceholder(description string) string {
	return fmt.Sprintf(`[Unit]
Description=%s
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=/bin/sleep infinity
Restart=always
RestartSec=2

[Install]
WantedBy=multi-user.target
`, description)
}

func unitTemplateReal(description, execStart, workDir string) string {
	return fmt.Sprintf(`[Unit]
Description=%s
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=globular
Group=globular
WorkingDirectory=%s
ExecStart=%s
Restart=on-failure
RestartSec=2

[Install]
WantedBy=multi-user.target
`, description, workDir, execStart)
}

func prefixedBinaryPath(ctx *Context, name string) string {
	return filepath.Join(ctx.Prefix, "bin", name)
}

func fileExists(path string) bool {
	st, err := os.Stat(path)
	if err != nil {
		return false
	}
	return st.Mode().IsRegular()
}

func unitDescription(unit string) string {
	switch unit {
	case "globular-envoy.service":
		return "Globular Envoy (placeholder)"
	case "globular-xds.service":
		return "Globular xDS (placeholder)"
	case "globular-gateway.service":
		return "Globular Gateway (placeholder)"
	default:
		return fmt.Sprintf("Globular service %s", unit)
	}
}
