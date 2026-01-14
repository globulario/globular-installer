package installer

import (
	"errors"
	"fmt"
	"os"
	"path/filepath"

	"github.com/globulario/globular-installer/internal/assets"
	"github.com/globulario/globular-installer/internal/installer/manifest"
	"github.com/globulario/globular-installer/internal/installer/spec"
	"github.com/globulario/globular-installer/internal/platform"
)

const (
	DefaultPrefix    = "/usr/lib/globular"
	DefaultStateDir  = "/var/lib/globular"
	DefaultConfigDir = "/etc/globular"
	DefaultLogDir    = "/var/log/globular"
)

type RuntimeState struct {
	ChangedBinaries       map[string]bool
	ChangedUnits          map[string]bool
	ChangedFiles          map[string]bool
	StagedPackageName     string
	StagedPackageVersion  string
	StagedPackagePlatform string
	StagedPackagePath     string
}

type Context struct {
	Version        string
	Prefix         string
	StateDir       string
	ConfigDir      string
	LogDir         string
	NonInteractive bool
	DryRun         bool
	Logger         Logger
	StagingDir     string
	Runtime        *RuntimeState
	Spec           *spec.InstallSpec
	SpecPath       string
	SpecInline     string
	TemplateVars   map[string]string
	Platform       platform.Platform
	Manifest       *manifest.Manifest
	ManifestPath   string
	Purge          bool
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

func (c *Context) LogDirPath() string {
	return c.LogDir
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
	logDir := opts.LogDir
	if logDir == "" {
		logDir = DefaultLogDir
	}

	for name, value := range map[string]string{
		"prefix":    prefix,
		"stateDir":  stateDir,
		"configDir": configDir,
		"logDir":    logDir,
	} {
		if !filepath.IsAbs(value) {
			return nil, fmt.Errorf("%s %q must be absolute", name, value)
		}
	}
	if opts.StagingDir != "" && !filepath.IsAbs(opts.StagingDir) {
		return nil, fmt.Errorf("stagingDir %q must be absolute", opts.StagingDir)
	}

	logger := NewStdLogger(opts.Verbose)

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
	xdsWatcherConfig := []byte("{}")
	if b, err := assets.ReadConfigAsset("xds/config.json"); err == nil && len(b) > 0 {
		xdsWatcherConfig = b
	}
	gatewayConfig := []byte("{}")
	if b, err := assets.ReadConfigAsset("gateway/config.json"); err == nil && len(b) > 0 {
		gatewayConfig = b
	}

	templateVars := map[string]string{
		"Prefix":            prefix,
		"StateDir":          stateDir,
		"ConfigDir":         configDir,
		"LogDir":            logDir,
		"Version":           opts.Version,
		"XDSConfigJSON":     string(xdsWatcherConfig),
		"GatewayConfigJSON": string(gatewayConfig),
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
		LogDir:         logDir,
		StagingDir:     opts.StagingDir,
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
		SpecInline:   opts.SpecInline,
		TemplateVars: templateVars,
		Platform:     plat,
		Manifest:     m,
		ManifestPath: mpath,
		Purge:        opts.Purge,
	}

	if logger != nil {
		logger.Infof("context: version=%q prefix=%q stateDir=%q configDir=%q logDir=%q dryRun=%v nonInteractive=%v",
			ctx.Version, ctx.Prefix, ctx.StateDir, ctx.ConfigDir, ctx.LogDir, ctx.DryRun, ctx.NonInteractive)
		logger.Infof("using spec %s", specDesc)
	}

	return ctx, nil
}

func (c *Context) LoadSpec(strict bool) (*spec.InstallSpec, error) {
	if strict && c.Spec != nil {
		return c.Spec, nil
	}
	if c.TemplateVars == nil {
		c.TemplateVars = map[string]string{
			"Prefix":            c.Prefix,
			"StateDir":          c.StateDir,
			"ConfigDir":         c.ConfigDir,
			"Version":           c.Version,
			"XDSConfigJSON":     "",
			"GatewayConfigJSON": "",
		}
	}
	if c.SpecInline != "" {
		return spec.LoadInlineWithMode(c.SpecInline, c.TemplateVars, strict)
	}
	if c.SpecPath != "" {
		return spec.LoadWithMode(c.SpecPath, c.TemplateVars, strict)
	}
	return spec.DefaultInstallSpec(c.TemplateVars), nil
}
