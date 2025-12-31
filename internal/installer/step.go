package installer

type StepStatus int

const (
	StatusUnknown StepStatus = iota
	StatusOK
	StatusNeedsApply
	StatusSkipped
)

func (s StepStatus) String() string {
	switch s {
	case StatusOK:
		return "ok"
	case StatusNeedsApply:
		return "needs-apply"
	case StatusSkipped:
		return "skipped"
	default:
		return "unknown"
	}
}

type Step interface {
	Name() string
	Check(ctx *Context) (StepStatus, error)
	Apply(ctx *Context) error
}

type StepResult struct {
	Name        string
	CheckStatus StepStatus
	Applied     bool
	Skipped     bool
	Err         error
}

func (r StepResult) Failed() bool {
	return r.Err != nil
}
