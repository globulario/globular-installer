package installer

import "strings"

type Options struct {
	Version          string
	Prefix           string
	StateDir         string
	ConfigDir        string
	LogDir           string
	MinioDataDir     string
	ServicePortRange string
	FeaturesCSV      string
	NonInteractive   bool
	DryRun           bool
	Force            bool
	Verbose          bool
	StagingDir       string
	SpecPath         string
	SpecInline       string
	Purge            bool
	// SkipStart suppresses start_services and health_checks steps.
	// Use during Day-1 join when you want the unit file installed and enabled
	// but the service started by the join script at a controlled point (e.g.
	// after writing a config file the service needs, like etcd.yaml).
	SkipStart bool
	// BootstrapEtcd is the etcd endpoint of the founding cluster node, used by
	// the etcd_join spec step to perform the Day-1 cluster join protocol.
	// Empty string means Day-0 (single-node bootstrap) — the etcd_join step is skipped.
	BootstrapEtcd string
	// ScriptEnv holds extra environment variables passed to run_script steps
	// (e.g. SCYLLA_INSTALL_INTENT=fresh-join on a Day-1 join so the ScyllaDB
	// post-install activates its fresh-join branch instead of the fail-safe
	// "preserve" default). Entries are appended after the standard variables so
	// a caller can override a default if needed. Nil is fine (no extra env).
	ScriptEnv map[string]string
}

func (o Options) Normalized() Options {
	o.Version = strings.TrimSpace(o.Version)
	o.Prefix = strings.TrimSpace(o.Prefix)
	o.StateDir = strings.TrimSpace(o.StateDir)
	o.ConfigDir = strings.TrimSpace(o.ConfigDir)
	o.LogDir = strings.TrimSpace(o.LogDir)
	o.MinioDataDir = strings.TrimSpace(o.MinioDataDir)
	o.ServicePortRange = strings.TrimSpace(o.ServicePortRange)
	o.FeaturesCSV = strings.TrimSpace(o.FeaturesCSV)
	o.StagingDir = strings.TrimSpace(o.StagingDir)
	o.SpecPath = strings.TrimSpace(o.SpecPath)
	o.SpecInline = strings.TrimSpace(o.SpecInline)
	o.BootstrapEtcd = strings.TrimSpace(o.BootstrapEtcd)
	return o
}
