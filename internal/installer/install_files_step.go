package installer

import (
	"bytes"
	"context"
	"fmt"
	"os"
	"path/filepath"

	"github.com/globulario/globular-installer/internal/platform"
)

// InstallFilesStep writes feature markers and other install-time files.
type InstallFilesStep struct {
	Files []platform.FileSpec
}

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
	files := s.filesToInstall(ctx)
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

func (s *InstallFilesStep) Apply(ctx *Context) error {
	if ctx == nil {
		return fmt.Errorf("nil context")
	}
	if ctx.Platform == nil {
		return fmt.Errorf("nil platform")
	}

	files := s.filesToInstall(ctx)

	if len(files) == 0 {
		return nil
	}

	changed := []string{}
	if installerWithResult, ok := ctx.Platform.(platform.FileInstallerWithResult); ok {
		result, err := installerWithResult.InstallFilesWithResult(context.Background(), files)
		if err != nil {
			return fmt.Errorf("install files: %w", err)
		}
		changed = append(changed, result.Changed...)
	} else {
		if err := ctx.Platform.InstallFiles(context.Background(), files); err != nil {
			return fmt.Errorf("install files: %w", err)
		}
		for _, spec := range files {
			changed = append(changed, spec.Path)
		}
	}
	if ctx.Runtime != nil {
		for _, path := range changed {
			ctx.Runtime.ChangedFiles[path] = true
		}
	}
	return nil
}

func (s *InstallFilesStep) filesToInstall(ctx *Context) []platform.FileSpec {
	if len(s.Files) > 0 {
		return s.Files
	}
	return buildFeatureMarkerFiles(ctx)
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
