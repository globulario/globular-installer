package spec

import (
	"bytes"
	"fmt"
	"os"
	"text/template"

	"gopkg.in/yaml.v3"
)

func Load(path string, vars map[string]string) (*InstallSpec, error) {
	return LoadWithMode(path, vars, true)
}

func LoadWithMode(path string, vars map[string]string, strict bool) (*InstallSpec, error) {
	data, err := os.ReadFile(path)
	if err != nil {
		return nil, err
	}
	return parseSpec(data, vars, strict)
}

func LoadInline(input string, vars map[string]string) (*InstallSpec, error) {
	return LoadInlineWithMode(input, vars, true)
}

func LoadInlineWithMode(input string, vars map[string]string, strict bool) (*InstallSpec, error) {
	return parseSpec([]byte(input), vars, strict)
}

func parseSpec(data []byte, vars map[string]string, strict bool) (*InstallSpec, error) {
	var spec InstallSpec
	if err := yaml.Unmarshal(data, &spec); err != nil {
		return nil, err
	}
	if err := applyTemplates(&spec, vars, strict); err != nil {
		return nil, err
	}
	if err := spec.Validate(); err != nil {
		return nil, err
	}
	return &spec, nil
}

func applyTemplates(spec *InstallSpec, vars map[string]string, strict bool) error {
	for idx := range spec.Steps {
		rendered, err := renderParams(spec.Steps[idx].Params, vars, strict)
		if err != nil {
			return err
		}
		spec.Steps[idx].Params = rendered
	}
	return nil
}

func renderParams(input map[string]any, vars map[string]string, strict bool) (map[string]any, error) {
	out := make(map[string]any, len(input))
	for key, value := range input {
		rendered, err := renderValue(value, vars, strict)
		if err != nil {
			return nil, fmt.Errorf("step param %q: %w", key, err)
		}
		out[key] = rendered
	}
	return out, nil
}

func renderValue(value any, vars map[string]string, strict bool) (any, error) {
	switch v := value.(type) {
	case string:
		return renderString(v, vars, strict)
	case map[string]any:
		return renderParams(v, vars, strict)
	case []any:
		result := make([]any, len(v))
		for i, element := range v {
			rendered, err := renderValue(element, vars, strict)
			if err != nil {
				return nil, err
			}
			result[i] = rendered
		}
		return result, nil
	default:
		return v, nil
	}
}

func renderString(input string, vars map[string]string, strict bool) (string, error) {
	option := "missingkey=error"
	if !strict {
		option = "missingkey=zero"
	}
	tmpl, err := template.New("").Option(option).Parse(input)
	if err != nil {
		return "", err
	}
	var buf bytes.Buffer
	if err := tmpl.Execute(&buf, vars); err != nil {
		return "", err
	}
	return buf.String(), nil
}
