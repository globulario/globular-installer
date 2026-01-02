package installer

import (
	"errors"
	"fmt"
	"os"
	"path/filepath"

	"github.com/globulario/globular-installer/internal/installer/manifest"
	"github.com/globulario/globular-installer/internal/installer/spec"
	"github.com/globulario/globular-installer/internal/platform"
)

const (
	DefaultPrefix    = "/usr/lib/globular"
	DefaultStateDir  = "/var/lib/globular"
	DefaultConfigDir = "/etc/globular"
)

type RuntimeState struct {
	ChangedBinaries map[string]bool
	ChangedUnits    map[string]bool
	ChangedFiles    map[string]bool
}

type Context struct {
	Version        string
	Prefix         string
	StateDir       string
	ConfigDir      string
	Features       FeatureSet
	NonInteractive bool
	DryRun         bool
	Logger         Logger
	StagingDir     string
	Runtime        *RuntimeState
	Spec           *spec.InstallSpec
	SpecPath       string
	Platform       platform.Platform
	Manifest       *manifest.Manifest
	ManifestPath   string
}

func (c *Context) PlatformBackend() platform.Platform {
	return c.Platform
}

func (c *Context) InstallPrefix() string {
	return c.Prefix
}

func (c *Context) StateDirPath() string {
	return c.StateDir
}

func (c *Context) ConfigDirPath() string {
	return c.ConfigDir
}

func NewContext(opts Options) (*Context, error) {
	opts = opts.Normalized()

	prefix := opts.Prefix
	if prefix == "" {
		prefix = DefaultPrefix
	}
	stateDir := opts.StateDir
	if stateDir == "" {
		stateDir = DefaultStateDir
	}
	configDir := opts.ConfigDir
	if configDir == "" {
		configDir = DefaultConfigDir
	}

	for name, value := range map[string]string{
		"prefix":    prefix,
		"stateDir":  stateDir,
		"configDir": configDir,
	} {
		if !filepath.IsAbs(value) {
			return nil, fmt.Errorf("%s %q must be absolute", name, value)
		}
	}
	if opts.StagingDir != "" && !filepath.IsAbs(opts.StagingDir) {
		return nil, fmt.Errorf("stagingDir %q must be absolute", opts.StagingDir)
	}

	logger := NewStdLogger(opts.Verbose)
	features := ParseFeatures(opts.FeaturesCSV)

	plat, err := platform.Detect()
	if err != nil {
		return nil, fmt.Errorf("detect platform: %w", err)
	}

	mpath := manifest.DefaultPath(stateDir)
	m, err := manifest.Load(mpath)
	if err != nil {
		if errors.Is(err, os.ErrNotExist) {
			m = manifest.New(opts.Version, prefix)
		} else {
			return nil, fmt.Errorf("load manifest %s: %w", mpath, err)
		}
	}

	var (
		specObj  *spec.InstallSpec
		specDesc string
	)
	templateVars := map[string]string{
		"Prefix":    prefix,
		"StateDir":  stateDir,
		"ConfigDir": configDir,
		"Version":   opts.Version,
	}
	if opts.SpecInline != "" {
		specObj, err = spec.LoadInline(opts.SpecInline, templateVars)
		if err != nil {
			return nil, fmt.Errorf("load spec inline: %w", err)
		}
		specDesc = "inline"
	} else if opts.SpecPath != "" {
		specObj, err = spec.Load(opts.SpecPath, templateVars)
		if err != nil {
			return nil, fmt.Errorf("load spec %s: %w", opts.SpecPath, err)
		}
		specDesc = fmt.Sprintf("path=%s", opts.SpecPath)
	} else {
		specObj = spec.DefaultInstallSpec(templateVars)
		specDesc = "default"
	}

	ctx := &Context{
		Version:        opts.Version,
		Prefix:         prefix,
		StateDir:       stateDir,
		ConfigDir:      configDir,
		StagingDir:     opts.StagingDir,
		Features:       features,
		NonInteractive: opts.NonInteractive,
		DryRun:         opts.DryRun,
		Logger:         logger,
		Runtime: &RuntimeState{
			ChangedBinaries: make(map[string]bool),
			ChangedUnits:    make(map[string]bool),
			ChangedFiles:    make(map[string]bool),
		},
		Spec:         specObj,
		SpecPath:     opts.SpecPath,
		Platform:     plat,
		Manifest:     m,
		ManifestPath: mpath,
	}

	if logger != nil {
		logger.Infof("context: version=%q prefix=%q stateDir=%q configDir=%q dryRun=%v nonInteractive=%v",
			ctx.Version, ctx.Prefix, ctx.StateDir, ctx.ConfigDir, ctx.DryRun, ctx.NonInteractive)
		logger.Infof("using spec %s", specDesc)
	}

	return ctx, nil
}
