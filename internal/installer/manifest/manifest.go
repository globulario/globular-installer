package manifest

type Manifest struct{}

func DefaultPath(stateDir string) string {
	_ = stateDir
	return ""
}

func Load(path string) (*Manifest, error) {
	_ = path
	return &Manifest{}, nil
}

func Save(path string, m *Manifest) error {
	_ = path
	_ = m
	return nil
}

func New(version, prefix string) *Manifest {
	_ = version
	_ = prefix
	return &Manifest{}
}
