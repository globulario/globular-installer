package installer

import (
	"fmt"
	"io/fs"
	"strconv"

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
		return NewInstallFilesStep(), nil
	case "install_services":
		return NewInstallServicesStep(), nil
	case "start_services":
		return NewStartServicesStep(), nil
	case "health_checks":
		return NewHealthChecksStep(), nil
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
	if val, ok := ss.Params["dirs"]; ok && val != nil {
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
	default:
		return 0, fmt.Errorf("unsupported mode type %T", val)
	}
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
			parsed, err := strconv.ParseBool(v)
			if err == nil {
				return parsed
			}
		}
	}
	return def
}
