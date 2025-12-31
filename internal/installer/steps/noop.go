package steps

type NoopStep struct{}

func NewNoop(name string) *NoopStep {
	_ = name
	return &NoopStep{}
}
