package installer

import (
	"context"
	"fmt"
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

	if err := ctx.Platform.InstallFiles(context.Background(), files); err != nil {
		return fmt.Errorf("install services: %w", err)
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

func buildUnitFiles(ctx *Context) []platform.FileSpec {
	out := make([]platform.FileSpec, 0)
	for _, unit := range enabledServiceUnitsInstall(ctx) {
		desc := unitDescription(unit)
		unitPath := filepath.Join("/etc/systemd/system", unit)
		out = append(out, platform.FileSpec{
			Path:   unitPath,
			Data:   []byte(unitTemplate(unit, desc)),
			Owner:  "root",
			Group:  "root",
			Mode:   0o644,
			Atomic: true,
		})
	}
	return out
}

func unitTemplate(unitName, description string) string {
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

func enabledServiceUnitsInstall(ctx *Context) []string {
	out := make([]string, 0, 3)
	if ctx.Features.Enabled(FeatureEnvoy) {
		out = append(out, "globular-envoy.service")
	}
	if ctx.Features.Enabled(FeatureXDS) {
		out = append(out, "globular-xds.service")
	}
	if ctx.Features.Enabled(FeatureGateway) {
		out = append(out, "globular-gateway.service")
	}
	return out
}
