//go:build windows

package bridge

import (
	"os"
	"os/exec"
)

// setProcessGroup is a no-op on Windows: Windows has no SetPGID equivalent at
// this level. If the Python worker spawns child processes that need killing
// alongside it, this would need a Job Object via golang.org/x/sys/windows.
// For the current cad worker (a single Python process that doesn't fork)
// this is sufficient.
func setProcessGroup(cmd *exec.Cmd) {
	// no-op
}

// terminateProcessGroup forcibly terminates p. Windows has no SIGTERM/SIGKILL
// distinction at this layer; both kinds collapse to immediate termination via
// TerminateProcess (what os.Process.Kill calls).
func terminateProcessGroup(p *os.Process, kind signalKind) error {
	return p.Kill()
}
