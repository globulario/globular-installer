package installer

import "fmt"

type Runner struct{}

func NewRunner() *Runner {
	return &Runner{}
}

type RunMode int

const (
	ModeApply RunMode = iota
	ModeCheckOnly
)

type RunReport struct {
	PlanName string
	Mode     RunMode
	Results  []StepResult
}

func (r *RunReport) Failed() bool {
	for _, res := range r.Results {
		if res.Err != nil {
			return true
		}
	}
	return false
}

func (r *RunReport) ErrorCount() int {
	count := 0
	for _, res := range r.Results {
		if res.Err != nil {
			count++
		}
	}
	return count
}

func (rn *Runner) Run(ctx *Context, p *Plan, mode RunMode) (*RunReport, error) {
	if ctx == nil {
		return nil, fmt.Errorf("context is required")
	}
	if p == nil {
		return nil, fmt.Errorf("plan is required")
	}
	if err := p.Validate(); err != nil {
		return nil, err
	}

	logger := ctx.Logger
	logInfo(logger, "running plan %q (mode=%v, dryRun=%v)", p.Name, mode, ctx.DryRun)

	report := &RunReport{PlanName: p.Name, Mode: mode}

	for idx, step := range p.Steps {
		if step == nil {
			err := fmt.Errorf("step %d in plan %q is nil", idx+1, p.Name)
			result := StepResult{Name: "<nil>", CheckStatus: StatusUnknown, Err: err}
			report.Results = append(report.Results, result)
			return report, err
		}

		stepName := step.Name()
		logDebug(logger, "check: %s", stepName)

		status, err := step.Check(ctx)
		result := StepResult{Name: stepName, CheckStatus: status}
		if status == StatusSkipped {
			result.Skipped = true
		}
		if err != nil {
			result.Err = err
			report.Results = append(report.Results, result)
			return report, err
		}

		if mode == ModeCheckOnly {
			report.Results = append(report.Results, result)
			continue
		}

		if mode == ModeApply && status == StatusNeedsApply {
			if ctx.DryRun {
				logInfo(logger, "dry-run: would apply %s", stepName)
				result.Skipped = true
				report.Results = append(report.Results, result)
				continue
			}

			logInfo(logger, "apply: %s", stepName)
			if err := step.Apply(ctx); err != nil {
				result.Err = err
				report.Results = append(report.Results, result)
				return report, err
			}

			result.Applied = true
			// Temporarily clear Force for the convergence re-check so steps
			// that unconditionally return NeedsApply when Force is set (e.g.
			// InstallBinariesStep) can verify files actually landed.
			savedForce := ctx.Force
			ctx.Force = false
			statusAfter, err := step.Check(ctx)
			ctx.Force = savedForce
			if err != nil {
				result.Err = err
				result.CheckStatus = statusAfter
				report.Results = append(report.Results, result)
				return report, err
			}
			result.CheckStatus = statusAfter
			result.Skipped = statusAfter == StatusSkipped
			if statusAfter == StatusNeedsApply {
				err := fmt.Errorf("step %s did not converge", stepName)
				result.Err = err
				report.Results = append(report.Results, result)
				return report, err
			}
		}

		report.Results = append(report.Results, result)
	}

	logInfo(logger, "plan %q completed: %d steps, %d errors", p.Name, len(report.Results), report.ErrorCount())
	if report.Failed() {
		return report, fmt.Errorf("plan %q completed with %d errors", p.Name, report.ErrorCount())
	}

	return report, nil
}

func logDebug(logger Logger, format string, args ...any) {
	if logger != nil {
		logger.Debugf(format, args...)
	}
}

func logInfo(logger Logger, format string, args ...any) {
	if logger != nil {
		logger.Infof(format, args...)
	}
}
