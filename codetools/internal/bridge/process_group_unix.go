//go:build unix

package bridge

import (
	"os"
	"os/exec"
	"syscall"
)

// setProcessGroup configures cmd to start in its own process group so that
// terminateProcessGroup can later signal the entire tree (worker + any
// grandchildren it spawned).
func setProcessGroup(cmd *exec.Cmd) {
	cmd.SysProcAttr = &syscall.SysProcAttr{Setpgid: true}
}

// terminateProcessGroup signals every process in the group whose leader is p.
// On Unix the worker is the group leader, so kill(-pid, sig) reaches it and
// any grandchildren in one shot.
func terminateProcessGroup(p *os.Process, kind signalKind) error {
	var sig syscall.Signal
	switch kind {
	case sigTerm:
		sig = syscall.SIGTERM
	case sigKill:
		sig = syscall.SIGKILL
	default:
		sig = syscall.SIGKILL
	}
	return syscall.Kill(-p.Pid, sig)
}
