package installer

import "strings"

type Options struct {
	Version          string
	Prefix           string
	StateDir         string
	ConfigDir        string
	LogDir           string
	ServicePortRange string
	FeaturesCSV      string
	NonInteractive   bool
	DryRun           bool
	Verbose          bool
	StagingDir       string
	SpecPath         string
	SpecInline       string
	Purge            bool
}

func (o Options) Normalized() Options {
	o.Version = strings.TrimSpace(o.Version)
	o.Prefix = strings.TrimSpace(o.Prefix)
	o.StateDir = strings.TrimSpace(o.StateDir)
	o.ConfigDir = strings.TrimSpace(o.ConfigDir)
	o.LogDir = strings.TrimSpace(o.LogDir)
	o.ServicePortRange = strings.TrimSpace(o.ServicePortRange)
	o.FeaturesCSV = strings.TrimSpace(o.FeaturesCSV)
	o.StagingDir = strings.TrimSpace(o.StagingDir)
	o.SpecPath = strings.TrimSpace(o.SpecPath)
	o.SpecInline = strings.TrimSpace(o.SpecInline)
	return o
}
