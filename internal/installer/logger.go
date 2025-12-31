package installer

import (
	"log"
	"os"
)

type Logger interface {
	Debugf(format string, args ...any)
	Infof(format string, args ...any)
	Warnf(format string, args ...any)
	Errorf(format string, args ...any)
}

type StdLogger struct {
	Verbose bool
	l       *log.Logger
}

func NewStdLogger(verbose bool) *StdLogger {
	return &StdLogger{
		Verbose: verbose,
		l:       log.New(os.Stderr, "", log.LstdFlags),
	}
}

func (s *StdLogger) Debugf(format string, args ...any) {
	if s == nil || !s.Verbose {
		return
	}
	s.ensure().Printf("DEBUG: "+format, args...)
}

func (s *StdLogger) Infof(format string, args ...any) {
	if s == nil {
		return
	}
	s.ensure().Printf("INFO: "+format, args...)
}

func (s *StdLogger) Warnf(format string, args ...any) {
	if s == nil {
		return
	}
	s.ensure().Printf("WARN: "+format, args...)
}

func (s *StdLogger) Errorf(format string, args ...any) {
	if s == nil {
		return
	}
	s.ensure().Printf("ERROR: "+format, args...)
}

func (s *StdLogger) ensure() *log.Logger {
	if s == nil {
		return log.New(os.Stderr, "", log.LstdFlags)
	}
	if s.l == nil {
		s.l = log.New(os.Stderr, "", log.LstdFlags)
	}
	return s.l
}
