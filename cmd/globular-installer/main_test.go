package main

import "testing"

func TestRunUninstallHelp(t *testing.T) {
	if got := run([]string{"prog", "uninstall", "--help"}); got != 0 {
		t.Fatalf("unexpected exit code: got %d want 0", got)
	}
}

func TestRunUnknownCommand(t *testing.T) {
	if got := run([]string{"prog", "unknown"}); got != 2 {
		t.Fatalf("unknown command exit: got %d want 2", got)
	}
}
