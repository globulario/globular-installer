package installer

import "strings"

type Feature string

const (
	FeatureEnvoy   Feature = "envoy"
	FeatureEtcd    Feature = "etcd"
	FeatureMinio   Feature = "minio"
	FeatureGateway Feature = "gateway"
	FeatureXDS     Feature = "xds"
)

// featureDefaults captures the installer defaults—gateway/xds/envoy on, etcd/minio off.
var featureDefaults = map[Feature]bool{
	FeatureEnvoy:   true,
	FeatureGateway: true,
	FeatureXDS:     true,
	FeatureEtcd:    false,
	FeatureMinio:   false,
}

type FeatureSet map[Feature]bool

// defaultFeatures returns a fresh copy of the hard-coded defaults.
func defaultFeatures() FeatureSet {
	m := make(FeatureSet, len(featureDefaults))
	for k, v := range featureDefaults {
		m[k] = v
	}
	return m
}

func (fs FeatureSet) Enabled(f Feature) bool {
	if fs == nil {
		return defaultValue(f)
	}
	if v, ok := fs[f]; ok {
		return v
	}
	return defaultValue(f)
}

func defaultValue(f Feature) bool {
	if v, ok := featureDefaults[f]; ok {
		return v
	}
	return false
}

// ParseFeatures translates a CSV-like list into a FeatureSet. Supported entries:
//
//	name                  enables the feature
//	name=true|false       sets the feature explicitly
//	no-name               disables the feature
//	enable:name           enables the feature
//	disable:name          disables the feature
//
// The tokens are case-insensitive, trimmed, and later entries override earlier ones.
// Unknown feature names are ignored (TODO).
func ParseFeatures(csv string) FeatureSet {
	fs := defaultFeatures()
	if strings.TrimSpace(csv) == "" {
		return fs
	}
	// Tokens are processed in order; later entries override earlier ones.
	tokens := strings.Split(csv, ",")
	for _, token := range tokens {
		entry := strings.TrimSpace(token)
		if entry == "" {
			continue
		}
		lower := strings.ToLower(entry)
		switch {
		case strings.Contains(lower, "="):
			parts := strings.SplitN(lower, "=", 2)
			if len(parts) != 2 {
				continue
			}
			if value, ok := parseBool(parts[1]); ok {
				setFeature(fs, parts[0], value)
			}
		case strings.HasPrefix(lower, "enable:"):
			name := strings.TrimPrefix(lower, "enable:")
			setFeature(fs, name, true)
		case strings.HasPrefix(lower, "disable:"):
			name := strings.TrimPrefix(lower, "disable:")
			setFeature(fs, name, false)
		case strings.HasPrefix(lower, "no-"):
			name := strings.TrimPrefix(lower, "no-")
			setFeature(fs, name, false)
		default:
			setFeature(fs, entry, true)
		}
	}
	return fs
}

func parseBool(s string) (bool, bool) {
	switch strings.ToLower(strings.TrimSpace(s)) {
	case "true":
		return true, true
	case "false":
		return false, true
	default:
		return false, false
	}
}

func NormalizeFeatureName(s string) Feature {
	return Feature(strings.ToLower(strings.TrimSpace(s)))
}

func setFeature(fs FeatureSet, name string, value bool) {
	feature := NormalizeFeatureName(name)
	if feature == "" {
		return
	}
	if _, ok := featureDefaults[feature]; !ok {
		// TODO: unknown features ignored
		return
	}
	fs[feature] = value
}
