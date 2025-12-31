package installer

import (
	"context"
	"fmt"
	"path/filepath"

	"github.com/globulario/globular-installer/internal/platform"
)

// InstallFilesStep writes feature markers and other install-time files.
type InstallFilesStep struct{}

func NewInstallFilesStep() *InstallFilesStep {
	return &InstallFilesStep{}
}

func (s *InstallFilesStep) Name() string {
	return "install-files"
}

func (s *InstallFilesStep) Check(ctx *Context) (StepStatus, error) {
	if ctx == nil {
		return StatusUnknown, fmt.Errorf("nil context")
	}
	if ctx.Platform == nil {
		return StatusUnknown, fmt.Errorf("nil platform")
	}
	return StatusNeedsApply, nil
}

func (s *InstallFilesStep) Apply(ctx *Context) error {
	if ctx == nil {
		return fmt.Errorf("nil context")
	}
	if ctx.Platform == nil {
		return fmt.Errorf("nil platform")
	}

	files := buildFeatureMarkerFiles(ctx)

	if len(files) == 0 {
		return nil
	}

	if err := ctx.Platform.InstallFiles(context.Background(), files); err != nil {
		return fmt.Errorf("install files: %w", err)
	}
	return nil
}

func buildFeatureMarkerFiles(ctx *Context) []platform.FileSpec {
	enabled := func(f Feature) bool {
		return ctx.Features.Enabled(f)
	}

	markers := []struct {
		Feature Feature
		Name    string
	}{
		{FeatureEnvoy, "envoy.enabled"},
		{FeatureXDS, "xds.enabled"},
		{FeatureGateway, "gateway.enabled"},
	}

	out := make([]platform.FileSpec, 0, len(markers))
	for _, m := range markers {
		if !enabled(m.Feature) {
			continue
		}
		path := filepath.Join(ctx.ConfigDir, "features", m.Name)
		out = append(out, platform.FileSpec{
			Path:   path,
			Data:   []byte("enabled\n"),
			Owner:  "root",
			Group:  "root",
			Mode:   0o644,
			Atomic: true,
		})
	}
	return out
}
