//go:build linux || darwin

package main

import (
	"errors"
	"os/exec"
	"syscall"
)

func configureDetached(child *exec.Cmd) {
	child.SysProcAttr = &syscall.SysProcAttr{Setsid: true}
}

func processAlive(pid int) bool {
	err := syscall.Kill(pid, 0)
	return err == nil || errors.Is(err, syscall.EPERM)
}
