package installer

import (
	"encoding/hex"
	"fmt"
	"io/fs"
	"net/url"
	"path/filepath"
	"sort"
	"strconv"
	"strings"
	"time"

	"github.com/globulario/globular-installer/internal/installer/spec"
	"github.com/globulario/globular-installer/internal/platform"
)

// BuildInstallPlan builds an installer.Plan from the provided spec.
func BuildInstallPlan(ctx *Context, sp *spec.InstallSpec) (*Plan, error) {
	if ctx == nil {
		return nil, fmt.Errorf("nil context")
	}
	if sp == nil {
		return nil, fmt.Errorf("nil spec")
	}
	if err := sp.Validate(); err != nil {
		return nil, err
	}

	steps := make([]Step, 0, len(sp.Steps))
	for _, ss := range sp.Steps {
		st, err := buildStep(ctx, ss)
		if err != nil {
			return nil, fmt.Errorf("spec step %q (%s): %w", ss.ID, ss.Type, err)
		}
		if st != nil {
			steps = append(steps, st)
		}
	}

	return NewPlan("install", steps...), nil
}

func buildStep(ctx *Context, ss spec.StepSpec) (Step, error) {
	switch ss.Type {
	case "ensure_user_group":
		return buildEnsureUserGroupStep(ss)
	case "ensure_dirs":
		return buildEnsureDirsStep(ss)
	case "install_binaries":
		return NewInstallBinariesStep(), nil
	case "install_files":
		step := NewInstallFilesStep()
		val, ok := ss.Params["files"]
		if ok {
			files, err := parseFileSpecs(val)
			if err != nil {
				return nil, err
			}
			if len(files) == 0 {
				return nil, fmt.Errorf("install_files step %q defined empty files list", ss.ID)
			}
			step.Files = files
			return step, nil
		}
		files, _, _, err := deriveInstallArtifacts(ctx.StagingDir, ctx.Prefix, ctx.ConfigDir, ctx.StateDir)
		if err != nil {
			return nil, err
		}
		if len(files) == 0 {
			return nil, fmt.Errorf("install_files step %q missing files definition and no installable payload found", ss.ID)
		}
		step.Files = files
		return step, nil
	case "install_services":
		step := NewInstallServicesStep()
		val, ok := ss.Params["units"]
		if ok {
			units, err := parseUnitSpecs(val)
			if err != nil {
				return nil, err
			}
			if len(units) == 0 {
				return nil, fmt.Errorf("install_services step %q defined empty units list", ss.ID)
			}
			step.Units = units
			return step, nil
		}
		_, units, _, err := deriveInstallArtifacts(ctx.StagingDir, ctx.Prefix, ctx.ConfigDir, ctx.StateDir)
		if err != nil {
			return nil, err
		}
		step.Units = units
		return step, nil
	case "start_services":
		step := NewStartServicesStep()
		services, err := getStringSliceParam(ss.Params, "services")
		if err != nil {
			return nil, err
		}
		if len(services) == 0 {
			_, _, derivedServices, derr := deriveInstallArtifacts(ctx.StagingDir, ctx.Prefix, ctx.ConfigDir, ctx.StateDir)
			if derr != nil {
				return nil, derr
			}
			services = derivedServices
		}
		if len(services) == 0 {
			return nil, fmt.Errorf("start_services step %q must declare services", ss.ID)
		}
		step.Services = services
		if restartMap, err := parseRestartOnFiles(ss.Params["restart_on_files"]); err != nil {
			return nil, err
		} else if len(restartMap) > 0 {
			step.RestartOnFiles = restartMap
		}
		if binMap, err := parseStringMap(ss.Params["binaries"]); err != nil {
			return nil, err
		} else if len(binMap) > 0 {
			step.Binaries = binMap
		}
		return step, nil
	case "health_checks":
		step := NewHealthChecksStep()
		services, err := getStringSliceParam(ss.Params, "services")
		if err != nil {
			return nil, err
		}
		if len(services) == 0 {
			_, _, derivedServices, derr := deriveInstallArtifacts(ctx.StagingDir, ctx.Prefix, ctx.ConfigDir, ctx.StateDir)
			if derr != nil {
				return nil, derr
			}
			services = derivedServices
		}
		if len(services) == 0 {
			return nil, fmt.Errorf("health_checks step %q must declare services", ss.ID)
		}
		step.Services = services
		if d, err := getDurationParam(ss.Params, "timeout"); err == nil && d > 0 {
			step.Timeout = d
		}
		if d, err := getDurationParam(ss.Params, "interval"); err == nil && d > 0 {
			step.Interval = d
		}
		return step, nil
	case "enable_services":
		step := NewEnableServicesStep()
		services, err := getStringSliceParam(ss.Params, "services")
		if err != nil {
			return nil, err
		}
		if len(services) == 0 {
			_, _, derivedServices, derr := deriveInstallArtifacts(ctx.StagingDir, ctx.Prefix, ctx.ConfigDir, ctx.StateDir)
			if derr != nil {
				return nil, derr
			}
			services = derivedServices
		}
		if len(services) == 0 {
			return nil, fmt.Errorf("enable_services step %q must declare services", ss.ID)
		}
		step.Services = services
		return step, nil
	case "install_packages":
		step, err := buildInstallPackagesStep(ss)
		if err != nil {
			return nil, err
		}
		return step, nil
	case "stage_package":
		return buildStagePackageStep(ss)
	case "install_package_payload":
		return buildInstallPackagePayloadStep(ss)
	case "install_os_packages":
		step := NewInstallOSPackagesStep()
		packages, err := getStringSliceParam(ss.Params, "packages")
		if err != nil {
			return nil, fmt.Errorf("install_os_packages: %w", err)
		}
		step.Packages = packages
		return step, nil
	case "fetch_file":
		step, err := buildFetchFileStep(ss)
		if err != nil {
			return nil, err
		}
		return step, nil
	case "ensure_service_config":
		step := &EnsureServiceConfigStep{
			ServiceName:         getStringParam(ss.Params, "service_name", ""),
			Exec:                getStringParam(ss.Params, "exec", ""),
			Domain:              getStringParam(ss.Params, "domain", ""),
			AddressHost:         getStringParam(ss.Params, "address_host", "localhost"),
			Owner:               getStringParam(ss.Params, "owner", "globular"),
			Group:               getStringParam(ss.Params, "group", "globular"),
			RewriteIfOutOfRange: getBoolParam(ss.Params, "rewrite_if_out_of_range", true),
		}
		if mv, ok := ss.Params["mode"]; ok {
			mode, err := parseMode(mv)
			if err != nil {
				return nil, fmt.Errorf("ensure_service_config step %q invalid mode: %w", ss.ID, err)
			}
			step.Mode = uint32(mode)
		}
		if step.Exec == "" {
			return nil, fmt.Errorf("ensure_service_config step %q missing exec", ss.ID)
		}
		return step, nil
	case "ensure_hosts_block":
		step := NewEnsureHostsBlockStep()
		step.HostsPath = getStringParam(ss.Params, "hosts_path", "/etc/hosts")
		step.ClusterDomain = getStringParam(ss.Params, "cluster_domain", "")
		step.NodeName = getStringParam(ss.Params, "node_name", "")
		step.AdvertiseIP = getStringParam(ss.Params, "advertise_ip", "")
		step.ControllerIP = getStringParam(ss.Params, "controller_ip", "")
		step.GatewayIP = getStringParam(ss.Params, "gateway_ip", "")
		step.Enabled = getBoolParam(ss.Params, "enabled", true)
		return step, nil
	case "remove_hosts_block":
		step := NewRemoveHostsBlockStep()
		step.HostsPath = getStringParam(ss.Params, "hosts_path", "/etc/hosts")
		step.ClusterDomain = getStringParam(ss.Params, "cluster_domain", "")
		return step, nil
	case "normalize_scylla_config":
		timeoutSec := 90
		if s := getStringParam(ss.Params, "timeout_sec", ""); s != "" {
			if n, err := strconv.Atoi(s); err == nil && n > 0 {
				timeoutSec = n
			}
		}
		step := &NormalizeScyllaConfigStep{
			ScyllaConfigPath:     getStringParam(ss.Params, "config_path", ""),
			ListenAddress:        getStringParam(ss.Params, "listen_address", ""),
			RPCAddress:           getStringParam(ss.Params, "rpc_address", ""),
			BroadcastAddress:     getStringParam(ss.Params, "broadcast_address", ""),
			BroadcastRPCAddress:  getStringParam(ss.Params, "broadcast_rpc_address", ""),
			NativeTransportPort:  getStringParam(ss.Params, "native_transport_port", ""),
			ValidatePort:         getBoolParam(ss.Params, "validate_port", true),
			ValidationTimeoutSec: timeoutSec,
		}
		return step, nil
	case "noop":
		name := ss.ID
		if name == "" {
			name = "install-placeholder"
		}
		return NewNoop(name), nil
	default:
		return nil, fmt.Errorf("unsupported step type %q", ss.Type)
	}
}

func buildEnsureUserGroupStep(ss spec.StepSpec) (Step, error) {
	userParam := getStringParam(ss.Params, "user", "globular")
	groupParam := getStringParam(ss.Params, "group", "globular")
	step := NewEnsureUserGroup(userParam, groupParam)
	step.Home = getStringParam(ss.Params, "home", "/var/lib/globular")
	step.Shell = getStringParam(ss.Params, "shell", "/usr/sbin/nologin")
	step.System = getBoolParam(ss.Params, "system", true)
	return step, nil
}

func buildEnsureDirsStep(ss spec.StepSpec) (Step, error) {
	step := NewEnsureDirs()
	if val, ok := ss.Params["dirs"]; ok {
		dirs, err := parseDirSpecs(val)
		if err != nil {
			return nil, err
		}
		if len(dirs) > 0 {
			step.Dirs = dirs
		}
	}
	return step, nil
}

func parseDirSpecs(val any) ([]platform.DirSpec, error) {
	rawList, ok := val.([]any)
	if !ok {
		return nil, fmt.Errorf("dirs must be a list")
	}
	out := make([]platform.DirSpec, 0, len(rawList))
	for idx, entry := range rawList {
		m, ok := entry.(map[string]any)
		if !ok {
			return nil, fmt.Errorf("dirs[%d] must be a map", idx)
		}
		path := getStringParam(m, "path", "")
		if path == "" {
			return nil, fmt.Errorf("dirs[%d] missing path", idx)
		}
		dir := platform.DirSpec{
			Path:  path,
			Owner: getStringParam(m, "owner", ""),
			Group: getStringParam(m, "group", ""),
		}
		if modeVal, exists := m["mode"]; exists {
			mode, err := parseMode(modeVal)
			if err != nil {
				return nil, fmt.Errorf("dirs[%d] invalid mode: %w", idx, err)
			}
			dir.Mode = mode
		}
		out = append(out, dir)
	}
	return out, nil
}

func parseFileSpecs(val any) ([]platform.FileSpec, error) {
	rawList, ok := val.([]any)
	if !ok {
		return nil, fmt.Errorf("files must be a list")
	}
	out := make([]platform.FileSpec, 0, len(rawList))
	for idx, entry := range rawList {
		m, ok := entry.(map[string]any)
		if !ok {
			return nil, fmt.Errorf("files[%d] must be a map", idx)
		}
		path := getStringParam(m, "path", "")
		if path == "" {
			return nil, fmt.Errorf("files[%d] missing path", idx)
		}
		content := getStringParam(m, "content", "")
		dir := platform.FileSpec{
			Path:   path,
			Data:   []byte(content),
			Owner:  getStringParam(m, "owner", "root"),
			Group:  getStringParam(m, "group", "root"),
			Mode:   getModeParam(m, "mode", 0o644),
			Atomic: getBoolParam(m, "atomic", true),
		}
		out = append(out, dir)
	}
	return out, nil
}

func parseUnitSpecs(val any) ([]platform.FileSpec, error) {
	rawList, ok := val.([]any)
	if !ok {
		return nil, fmt.Errorf("units must be a list")
	}
	out := make([]platform.FileSpec, 0, len(rawList))
	for idx, entry := range rawList {
		m, ok := entry.(map[string]any)
		if !ok {
			return nil, fmt.Errorf("units[%d] must be a map", idx)
		}
		name := getStringParam(m, "name", "")
		if name == "" {
			return nil, fmt.Errorf("units[%d] missing name", idx)
		}
		content := getStringParam(m, "content", "")
		spec := platform.FileSpec{
			Path:   filepath.Join("/etc/systemd/system", name),
			Data:   []byte(content),
			Owner:  getStringParam(m, "owner", "root"),
			Group:  getStringParam(m, "group", "root"),
			Mode:   getModeParam(m, "mode", 0o644),
			Atomic: getBoolParam(m, "atomic", true),
		}
		out = append(out, spec)
	}
	return out, nil
}

func buildInstallPackagesStep(ss spec.StepSpec) (Step, error) {
	step := NewInstallPackagesStep()
	manager := getStringParam(ss.Params, "manager", "apt")
	if manager != "apt" {
		return nil, fmt.Errorf("install_packages step %q unsupported manager %q", ss.ID, manager)
	}
	pkgs, err := parsePackageSpecs(ss.Params["packages"])
	if err != nil {
		return nil, err
	}
	if len(pkgs) == 0 {
		return nil, fmt.Errorf("install_packages step %q must declare packages", ss.ID)
	}
	step.Manager = manager
	step.Packages = pkgs
	return step, nil
}

func buildStagePackageStep(ss spec.StepSpec) (Step, error) {
	path := getStringParam(ss.Params, "path", "")
	if path == "" {
		return nil, fmt.Errorf("stage_package step %q missing path", ss.ID)
	}
	step := &StagePackageStep{
		Path:                 path,
		VerifySHA256:         getStringParam(ss.Params, "verify_sha256", ""),
		CacheDir:             getStringParam(ss.Params, "cache_dir", "/var/lib/globular/cache/packages"),
		StagingRoot:          getStringParam(ss.Params, "staging_root", "/var/lib/globular/staging/packages"),
		RequirePlatformMatch: getBoolParam(ss.Params, "require_platform_match", true),
		RequireTypeService:   getBoolParam(ss.Params, "require_type_service", true),
	}
	return step, nil
}

func buildInstallPackagePayloadStep(ss spec.StepSpec) (Step, error) {
	step := &InstallPackagePayloadStep{
		Prefix:          getStringParam(ss.Params, "prefix", ""),
		InstallBins:     getBoolParam(ss.Params, "install_bins", false),
		InstallConfig:   getBoolParam(ss.Params, "install_config", true),
		InstallSpec:     getBoolParam(ss.Params, "install_spec", true),
		InstallSystemd:  getBoolParam(ss.Params, "install_systemd", true),
		ConfigDestRoot:  getStringParam(ss.Params, "config_dest_root", "/var/lib/globular/services"),
		SpecDestRoot:    getStringParam(ss.Params, "spec_dest_root", "/var/lib/globular/specs"),
		SystemdDestRoot: getStringParam(ss.Params, "systemd_dest_root", "/etc/systemd/system"),
		ReloadSystemd:   getBoolParam(ss.Params, "reload_systemd", true),
	}
	return step, nil
}

func parsePackageSpecs(val any) ([]PackageSpec, error) {
	rawList, ok := val.([]any)
	if !ok {
		return nil, fmt.Errorf("packages must be a list")
	}
	out := make([]PackageSpec, 0, len(rawList))
	for idx, entry := range rawList {
		m, ok := entry.(map[string]any)
		if !ok {
			return nil, fmt.Errorf("packages[%d] must be a map", idx)
		}
		name := getStringParam(m, "name", "")
		if name == "" {
			return nil, fmt.Errorf("packages[%d] missing name", idx)
		}
		out = append(out, PackageSpec{
			Name:    name,
			Version: getStringParam(m, "version", ""),
		})
	}
	return out, nil
}

func buildFetchFileStep(ss spec.StepSpec) (Step, error) {
	urlStr := getStringParam(ss.Params, "url", "")
	to := getStringParam(ss.Params, "to", "")
	sha := strings.ToLower(strings.TrimSpace(getStringParam(ss.Params, "sha256", "")))
	if urlStr == "" {
		return nil, fmt.Errorf("fetch_file step %q missing url", ss.ID)
	}
	if to == "" {
		return nil, fmt.Errorf("fetch_file step %q missing destination", ss.ID)
	}
	if sha == "" {
		return nil, fmt.Errorf("fetch_file step %q missing sha256", ss.ID)
	}
	if len(sha) != 64 {
		return nil, fmt.Errorf("fetch_file step %q sha256 must be 64 hex digits", ss.ID)
	}
	if _, err := hex.DecodeString(sha); err != nil {
		return nil, fmt.Errorf("fetch_file step %q sha256 invalid: %w", ss.ID, err)
	}
	parsed, err := url.Parse(urlStr)
	if err != nil {
		return nil, fmt.Errorf("fetch_file step %q invalid url: %w", ss.ID, err)
	}
	if parsed.Scheme != "https" {
		return nil, fmt.Errorf("fetch_file step %q url must use https", ss.ID)
	}
	destMode := getModeParam(ss.Params, "mode", 0)
	step := &FetchFileStep{
		URL:    urlStr,
		To:     to,
		Sha256: sha,
		Mode:   destMode,
		Owner:  getStringParam(ss.Params, "owner", "root"),
		Group:  getStringParam(ss.Params, "group", "root"),
		Binary: getBoolParam(ss.Params, "binary", false),
	}
	return step, nil
}

// BuildUninstallPlan builds an uninstall plan derived from the install spec.
func BuildUninstallPlan(ctx *Context, sp *spec.InstallSpec) (*Plan, error) {
	if ctx == nil {
		return nil, fmt.Errorf("nil context")
	}
	if sp == nil {
		return nil, fmt.Errorf("nil spec")
	}
	if err := sp.Validate(); err != nil {
		return nil, err
	}

	serviceSet := make(map[string]struct{})
	unitMap := make(map[string]platform.FileSpec)
	fileMap := make(map[string]platform.FileSpec)
	binarySet := make(map[string]struct{})

	for _, ss := range sp.Steps {
		switch ss.Type {
		case "start_services":
			services, err := getStringSliceParam(ss.Params, "services")
			if err != nil {
				return nil, err
			}
			for _, svc := range services {
				serviceSet[svc] = struct{}{}
			}
			if binMap, err := parseStringMap(ss.Params["binaries"]); err != nil {
				return nil, err
			} else {
				for _, binName := range binMap {
					path := filepath.Join(ctx.Prefix, "bin", binName)
					binarySet[path] = struct{}{}
				}
			}
		case "install_services":
			if val, ok := ss.Params["units"]; ok {
				units, err := parseUnitSpecs(val)
				if err != nil {
					return nil, err
				}
				for _, unit := range units {
					unitMap[unit.Path] = unit
				}
			}
		case "install_files":
			if val, ok := ss.Params["files"]; ok {
				files, err := parseFileSpecs(val)
				if err != nil {
					return nil, err
				}
				for _, file := range files {
					fileMap[file.Path] = file
				}
			}
		}
	}

	steps := make([]Step, 0, 4)

	if len(serviceSet) > 0 {
		services := mapKeys(serviceSet)
		steps = append(steps, &StopServicesStep{Services: services})
	}
	if len(unitMap) > 0 {
		units := mapValues(unitMap)
		steps = append(steps, &UninstallServicesStep{Units: units})
	}
	if len(fileMap) > 0 {
		files := mapValues(fileMap)
		steps = append(steps, &UninstallFilesStep{Files: files})
	}
	if len(binarySet) > 0 {
		paths := mapKeys(binarySet)
		steps = append(steps, &UninstallBinariesStep{Paths: paths})
	}

	if len(steps) == 0 {
		return NewPlan("uninstall"), nil
	}
	return NewPlan("uninstall", steps...), nil
}

func mapKeys(set map[string]struct{}) []string {
	out := make([]string, 0, len(set))
	for key := range set {
		out = append(out, key)
	}
	sort.Strings(out)
	return out
}

func mapValues(m map[string]platform.FileSpec) []platform.FileSpec {
	out := make([]platform.FileSpec, 0, len(m))
	keys := make([]string, 0, len(m))
	for p := range m {
		keys = append(keys, p)
	}
	sort.Strings(keys)
	for _, k := range keys {
		out = append(out, m[k])
	}
	return out
}

func parseRestartOnFiles(val any) (map[string][]string, error) {
	if val == nil {
		return nil, nil
	}
	m, ok := val.(map[string]any)
	if !ok {
		return nil, fmt.Errorf("restart_on_files must be a map")
	}
	out := make(map[string][]string, len(m))
	for unit, entry := range m {
		list, err := parseStringList(entry)
		if err != nil {
			return nil, fmt.Errorf("restart_on_files[%s]: %w", unit, err)
		}
		out[unit] = list
	}
	return out, nil
}

func parseStringList(val any) ([]string, error) {
	switch v := val.(type) {
	case []string:
		return v, nil
	case []any:
		out := make([]string, 0, len(v))
		for idx, elem := range v {
			s, ok := elem.(string)
			if !ok {
				return nil, fmt.Errorf("entry[%d] must be a string", idx)
			}
			out = append(out, s)
		}
		return out, nil
	default:
		return nil, fmt.Errorf("must be list of strings")
	}
}

func parseStringMap(val any) (map[string]string, error) {
	if val == nil {
		return nil, nil
	}
	m, ok := val.(map[string]any)
	if !ok {
		return nil, fmt.Errorf("must be a map of strings")
	}
	out := make(map[string]string, len(m))
	for key, entry := range m {
		s, ok := entry.(string)
		if !ok {
			return nil, fmt.Errorf("binaries[%s] must be a string", key)
		}
		out[key] = s
	}
	return out, nil
}

func parseMode(val any) (fs.FileMode, error) {
	switch v := val.(type) {
	case int:
		return fs.FileMode(v), nil
	case int64:
		return fs.FileMode(v), nil
	case float64:
		return fs.FileMode(int(v)), nil
	case string:
		if v == "" {
			return 0, nil
		}
		parsed, err := strconv.ParseUint(v, 0, 32)
		if err != nil {
			return 0, err
		}
		return fs.FileMode(parsed), nil
	}
	return 0, fmt.Errorf("unsupported mode type %T", val)
}

func getModeParam(params map[string]any, key string, def fs.FileMode) fs.FileMode {
	if params == nil {
		return def
	}
	if val, ok := params[key]; ok {
		if parsed, err := parseMode(val); err == nil && parsed != 0 {
			return parsed
		}
	}
	return def
}

func getStringParam(params map[string]any, key, def string) string {
	if params == nil {
		return def
	}
	if raw, ok := params[key]; ok {
		if s, ok := raw.(string); ok {
			return s
		}
	}
	return def
}

func getBoolParam(params map[string]any, key string, def bool) bool {
	if params == nil {
		return def
	}
	if raw, ok := params[key]; ok {
		switch v := raw.(type) {
		case bool:
			return v
		case string:
			if parsed, err := strconv.ParseBool(v); err == nil {
				return parsed
			}
		}
	}
	return def
}

func getStringSliceParam(params map[string]any, key string) ([]string, error) {
	if params == nil {
		return nil, nil
	}
	raw, ok := params[key]
	if !ok || raw == nil {
		return nil, nil
	}
	switch v := raw.(type) {
	case []string:
		return v, nil
	case []any:
		out := make([]string, 0, len(v))
		for idx, elem := range v {
			s, ok := elem.(string)
			if !ok {
				return nil, fmt.Errorf("%s[%d] must be a string", key, idx)
			}
			out = append(out, s)
		}
		return out, nil
	default:
		return nil, fmt.Errorf("%s must be a list of strings", key)
	}
}

func getDurationParam(params map[string]any, key string) (time.Duration, error) {
	if params == nil {
		return 0, nil
	}
	raw, ok := params[key]
	if !ok || raw == nil {
		return 0, nil
	}
	switch v := raw.(type) {
	case string:
		return time.ParseDuration(v)
	default:
		return 0, fmt.Errorf("%s must be a duration string", key)
	}
}
