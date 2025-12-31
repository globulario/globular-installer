package installer

import "strings"

type Options struct {
	Version        string
	Prefix         string
	StateDir       string
	ConfigDir      string
	FeaturesCSV    string
	NonInteractive bool
	DryRun         bool
	Verbose        bool
	StagingDir     string
}

func (o Options) Normalized() Options {
	o.Version = strings.TrimSpace(o.Version)
	o.Prefix = strings.TrimSpace(o.Prefix)
	o.StateDir = strings.TrimSpace(o.StateDir)
	o.ConfigDir = strings.TrimSpace(o.ConfigDir)
	o.FeaturesCSV = strings.TrimSpace(o.FeaturesCSV)
	o.StagingDir = strings.TrimSpace(o.StagingDir)
	return o
}
