package installer

type Logger interface{}

type StdLogger struct{}

func NewStdLogger(verbose bool) *StdLogger {
	_ = verbose
	return &StdLogger{}
}
