package main

import (
	"flag"
	"fmt"
	"io"
	"os"
	"strings"

	"github.com/globulario/globular-installer/pkg/installer"
)

var availableCommands = []string{"install", "doctor", "status", "uninstall"}

func main() {
	os.Exit(run(os.Args))
}

func run(args []string) int {
	prog := "<program>"
	if len(args) > 0 && args[0] != "" {
		prog = args[0]
	}

	if len(args) < 2 {
		usageWithName(os.Stderr, prog)
		return 2
	}

	cmd := args[1]
	if isGlobalHelp(cmd) {
		usageWithName(os.Stdout, prog)
		return 0
	}

	switch cmd {
	case "install", "doctor", "status", "uninstall":
		return runCommand(prog, cmd, args[2:])
	default:
		fmt.Fprintf(os.Stderr, "unknown command %q\n", cmd)
		usageWithName(os.Stderr, prog)
		return 2
	}
}

func runCommand(prog, cmd string, args []string) int {
	fs := flag.NewFlagSet(cmd, flag.ContinueOnError)
	fs.SetOutput(io.Discard)

	prefix := fs.String("prefix", "", "installation prefix")
	stateDir := fs.String("state-dir", "", "state directory")
	configDir := fs.String("config-dir", "", "configuration directory")
	logDir := fs.String("log-dir", "", "log directory")
	minioDataDir := fs.String("minio-data-dir", "", "MinIO data storage directory (default: <state-dir>/minio/data)")
	features := fs.String("features", "", "comma-separated feature list")
	stagingDir := fs.String("staging-dir", "", "staging directory for binaries")
	specPath := fs.String("spec", "", "path to YAML/JSON install spec")
	specInline := fs.String("spec-inline", "", "inline spec content (YAML/JSON)")
	portRange := fs.String("port-range", "10000-11000", "service port range (start-end)")
	dryRun := fs.Bool("dry-run", false, "perform a dry run")
	force := fs.Bool("force", false, "force reinstall even if binaries are already up-to-date")
	purge := fs.Bool("purge", false, "remove config/state dirs when uninstalling")
	nonInteractive := fs.Bool("non-interactive", false, "run without prompts")
	verbose := fs.Bool("verbose", false, "enable verbose logging")
	version := fs.String("version", "", "globular version being installed")
	help := fs.Bool("help", false, "show help")
	helpShort := fs.Bool("h", false, "show help")

	if err := fs.Parse(args); err != nil {
		fmt.Fprintf(os.Stderr, "%v\n", err)
		printCommandUsage(os.Stderr, prog, cmd)
		return 2
	}

	if *help || *helpShort {
		printCommandUsage(os.Stdout, prog, cmd)
		return 0
	}

	remaining := fs.Args()

	opts := installer.Options{
		Version:          *version,
		Prefix:           *prefix,
		StateDir:         *stateDir,
		ConfigDir:        *configDir,
		LogDir:           *logDir,
		MinioDataDir:     *minioDataDir,
		ServicePortRange: *portRange,
		FeaturesCSV:      *features,
		StagingDir:       *stagingDir,
		SpecPath:         *specPath,
		SpecInline:       *specInline,
		DryRun:           *dryRun,
		Force:            *force,
		NonInteractive:   *nonInteractive,
		Verbose:          *verbose,
		Purge:            *purge,
	}

	// If a package path is provided as a positional argument and no spec or staging
	// dir is set, extract the package to a temp staging directory for default installs,
	// but only when the argument looks like a package archive.
	if cmd == "install" && opts.SpecPath == "" && opts.SpecInline == "" && opts.StagingDir == "" && len(remaining) > 0 {
		arg := remaining[0]
		lower := strings.ToLower(arg)
		if strings.HasSuffix(lower, ".tgz") || strings.HasSuffix(lower, ".tar.gz") {
			stagingDir, err := installer.ExtractPackageToTemp(arg)
			if err != nil {
				fmt.Fprintf(os.Stderr, "error staging package %s: %v\n", arg, err)
				return 1
			}
			opts.StagingDir = stagingDir
		}
	}

	ctx, err := installer.NewContext(opts)
	if err != nil {
		fmt.Fprintf(os.Stderr, "error: %v\n", err)
		return 1
	}

	var report *installer.RunReport
	var runErr error
	switch cmd {
	case "install":
		report, runErr = installer.Install(ctx)
	case "doctor":
		report, runErr = installer.Doctor(ctx)
	case "status":
		report, runErr = installer.Status(ctx)
	case "uninstall":
		report, runErr = installer.Uninstall(ctx)
	}

	printReport(os.Stdout, cmd, report)
	if runErr != nil {
		fmt.Fprintf(os.Stderr, "error: %v\n", runErr)
		return 1
	}

	return 0
}

func usageWithName(w io.Writer, prog string) {
	fmt.Fprintf(w, "usage: %s <command> [flags]\n\n", prog)
	fmt.Fprintf(w, "Commands: %s\n", strings.Join(availableCommands, ", "))
	fmt.Fprintf(w, "Use \"%s <command> --help\" for details.\n", prog)
}

func printCommandUsage(w io.Writer, prog, cmd string) {
	fmt.Fprintf(w, "usage: %s %s [flags]\n\n", prog, cmd)
	fmt.Fprintln(w, "Flags:")
	fmt.Fprintln(w, "  --prefix string          installation prefix")
	fmt.Fprintln(w, "  --state-dir string       state directory")
	fmt.Fprintln(w, "  --config-dir string      configuration directory")
	fmt.Fprintln(w, "  --log-dir string         log directory")
	fmt.Fprintln(w, "  --minio-data-dir string  MinIO data storage directory (default: <state-dir>/minio/data)")
	fmt.Fprintln(w, "  --port-range string      service port range (start-end)")
	fmt.Fprintln(w, "  --features string        feature list (csv or enable:prefix)")
	fmt.Fprintln(w, "  --staging-dir string     staging directory with bin/ artifacts")
	fmt.Fprintln(w, "  --spec string            path to YAML/JSON install spec")
	fmt.Fprintln(w, "  --spec-inline string     inline spec contents (YAML/JSON)")
	fmt.Fprintln(w, "  --dry-run                run without making system changes")
	fmt.Fprintln(w, "  --force                  force reinstall even if binaries are already up-to-date")
	fmt.Fprintln(w, "  --non-interactive        run without prompts")
	fmt.Fprintln(w, "  --verbose                print verbose logs")
	fmt.Fprintln(w, "  --version string         globular version metadata")
	fmt.Fprintln(w, "  --purge                  remove config/state dirs when uninstalling")
	fmt.Fprintln(w, "  --help, -h               show this help")

	fmt.Fprintln(w)
	fmt.Fprintln(w, "Examples:")
	fmt.Fprintf(w, "  %s uninstall --purge --state-dir /var/lib/globular\n", prog)
}

func printReport(w io.Writer, cmd string, rep *installer.RunReport) {
	fmt.Fprintf(w, "command: %s\n", cmd)
	if rep == nil {
		fmt.Fprintln(w, "no report")
		return
	}

	failed := 0
	for _, res := range rep.Results {
		name := stepName(res)
		status := stepStatusAny(res)
		line := fmt.Sprintf("- %s: %s", name, status)
		details := []string{}
		if res.Applied {
			details = append(details, "applied")
		}
		if res.Skipped {
			details = append(details, "skipped")
		}
		if errMsg := stepErrorAny(res); errMsg != "" {
			details = append(details, fmt.Sprintf("error=%s", errMsg))
			failed++
		}
		if len(details) > 0 {
			line += " (" + strings.Join(details, ", ") + ")"
		}
		fmt.Fprintln(w, line)
	}
	fmt.Fprintf(w, "steps: %d, failed: %d\n", len(rep.Results), failed)
}

func stepName(res installer.StepResult) string {
	if res.Name != "" {
		return res.Name
	}
	return "<unknown>"
}

func stepStatusAny(res installer.StepResult) string {
	if res.CheckStatus != 0 {
		return fmt.Sprint(res.CheckStatus)
	}
	return "<unknown>"
}

func stepErrorAny(res installer.StepResult) string {
	if res.Err != nil {
		return fmt.Sprint(res.Err)
	}
	return ""
}

func runModeString(mode installer.RunMode) string {
	switch mode {
	case installer.ModeApply:
		return "apply"
	case installer.ModeCheckOnly:
		return "check-only"
	default:
		return "unknown"
	}
}

func isGlobalHelp(cmd string) bool {
	switch cmd {
	case "help", "-h", "--help":
		return true
	default:
		return false
	}
}
