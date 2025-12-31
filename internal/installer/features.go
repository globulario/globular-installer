package installer

type Feature string

type FeatureSet map[Feature]bool

func ParseFeatures(csv string) FeatureSet {
	_ = csv
	return FeatureSet{}
}

func (fs FeatureSet) Enabled(f Feature) bool {
	if fs == nil {
		return false
	}
	return fs[f]
}
