package installer

import (
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"strconv"
	"strings"

	"github.com/globulario/globular-installer/pkg/assets"
	"github.com/globulario/globular-installer/pkg/installer/manifest"
	"github.com/globulario/globular-installer/pkg/installer/spec"
	"github.com/globulario/globular-installer/pkg/platform"
)

const (
	DefaultPrefix      = "/usr/lib/globular"
	DefaultStateDir    = "/var/lib/globular"
	DefaultConfigDir   = "/var/lib/globular/services" // Services store configs as <uuid>.json
	DefaultServicesDir = "/var/lib/globular/services" // Alias for clarity
	DefaultLogDir      = "/var/log/globular"
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
	PortRangeStart int
	PortRangeEnd   int
	NonInteractive bool
	DryRun         bool
	Force          bool
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
	Ports          *PortAllocator
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

	portRange := opts.ServicePortRange
	if portRange == "" {
		portRange = "10000-11000"
	}
	rangeStart, rangeEnd, err := parsePortRange(portRange)
	if err != nil {
		return nil, fmt.Errorf("port-range %q: %w", portRange, err)
	}
	portAllocator, err := NewPortAllocator(rangeStart, rangeEnd)
	if err != nil {
		return nil, fmt.Errorf("init port allocator: %w", err)
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
	specPath := opts.SpecPath
	xdsWatcherConfig := []byte("{}")
	if b, err := assets.ReadConfigAsset("xds/config.json"); err == nil && len(b) > 0 {
		xdsWatcherConfig = b
	}
	gatewayConfig := []byte("{}")
	if b, err := assets.ReadConfigAsset("gateway/config.json"); err == nil && len(b) > 0 {
		gatewayConfig = b
	}

	minioDataDir := opts.MinioDataDir
	if minioDataDir == "" {
		minioDataDir = filepath.Join(stateDir, "minio", "data")
	}

	nodeIP := "127.0.0.1"
	if ip, err := detectPrimaryIP(); err == nil {
		nodeIP = ip
	}

	templateVars := map[string]string{
		"Prefix":            prefix,
		"StateDir":          stateDir,
		"ConfigDir":         configDir,
		"LogDir":            logDir,
		"MinioDataDir":      minioDataDir,
		"Version":           opts.Version,
		"PortRangeStart":    strconv.Itoa(rangeStart),
		"PortRangeEnd":      strconv.Itoa(rangeEnd),
		"XDSConfigJSON":     string(xdsWatcherConfig),
		"GatewayConfigJSON": string(gatewayConfig),
		"NodeIP":            nodeIP,
	}
	if specPath == "" && opts.SpecInline == "" && opts.StagingDir != "" {
		manifestPath := filepath.Join(opts.StagingDir, "package.json")
		if mf, err := loadPackageManifest(manifestPath); err == nil && mf.Defaults.Spec != "" {
			if filepath.IsAbs(mf.Defaults.Spec) {
				if logger != nil {
					logger.Infof("ignoring absolute spec path %s in package", mf.Defaults.Spec)
				}
			} else {
				candidate := filepath.Join(opts.StagingDir, filepath.Clean(mf.Defaults.Spec))
				if info, err := os.Stat(candidate); err == nil && !info.IsDir() {
					specPath = candidate
				} else if err != nil && logger != nil && !errors.Is(err, os.ErrNotExist) {
					logger.Infof("unable to use package spec %s: %v", candidate, err)
				}
			}
		}
	}
	if opts.SpecInline != "" {
		specObj, err = spec.LoadInline(opts.SpecInline, templateVars)
		if err != nil {
			return nil, fmt.Errorf("load spec inline: %w", err)
		}
		specDesc = "inline"
	} else if specPath != "" {
		specObj, err = spec.Load(specPath, templateVars)
		if err != nil {
			return nil, fmt.Errorf("load spec %s: %w", specPath, err)
		}
		specDesc = fmt.Sprintf("path=%s", specPath)
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
		Force:          opts.Force,
		Logger:         logger,
		Runtime: &RuntimeState{
			ChangedBinaries: make(map[string]bool),
			ChangedUnits:    make(map[string]bool),
			ChangedFiles:    make(map[string]bool),
		},
		PortRangeStart: rangeStart,
		PortRangeEnd:   rangeEnd,
		Ports:          portAllocator,
		Spec:           specObj,
		SpecPath:       specPath,
		SpecInline:     opts.SpecInline,
		TemplateVars:   templateVars,
		Platform:       plat,
		Manifest:       m,
		ManifestPath:   mpath,
		Purge:          opts.Purge,
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
		nodeIP := "127.0.0.1"
		if ip, err := detectPrimaryIP(); err == nil {
			nodeIP = ip
		}
		c.TemplateVars = map[string]string{
			"Prefix":            c.Prefix,
			"StateDir":          c.StateDir,
			"ConfigDir":         c.ConfigDir,
			"Version":           c.Version,
			"XDSConfigJSON":     "",
			"GatewayConfigJSON": "",
			"NodeIP":            nodeIP,
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

func parsePortRange(val string) (int, int, error) {
	parts := strings.FieldsFunc(val, func(r rune) bool {
		return r == '-' || r == ':' || r == ','
	})
	if len(parts) != 2 {
		return 0, 0, fmt.Errorf("expected start-end")
	}
	start, err := strconv.Atoi(parts[0])
	if err != nil {
		return 0, 0, fmt.Errorf("invalid start port: %w", err)
	}
	end, err := strconv.Atoi(parts[1])
	if err != nil {
		return 0, 0, fmt.Errorf("invalid end port: %w", err)
	}
	if start <= 0 || end <= 0 || start > 65535 || end > 65535 {
		return 0, 0, fmt.Errorf("ports must be between 1 and 65535")
	}
	if start >= end {
		return 0, 0, fmt.Errorf("start must be less than end")
	}
	return start, end, nil
}
