package main

import (
	"os/exec"
	"syscall"

	"golang.org/x/sys/windows"
)

func configureDetached(child *exec.Cmd) {
	child.SysProcAttr = &syscall.SysProcAttr{CreationFlags: windows.CREATE_NEW_PROCESS_GROUP | windows.DETACHED_PROCESS}
}

func processAlive(pid int) bool {
	handle, err := windows.OpenProcess(windows.PROCESS_QUERY_LIMITED_INFORMATION, false, uint32(pid))
	if err != nil {
		return false
	}
	var code uint32
	queryErr := windows.GetExitCodeProcess(handle, &code)
	closeErr := windows.CloseHandle(handle)
	return queryErr == nil && closeErr == nil && code == 259 // STILL_ACTIVE
}
