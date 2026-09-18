package main

import (
	"fmt"
	"os"
	"path/filepath"

	sharedruntime "github.com/imrans-lab/minerva-plugins/shared/runtime"
)

func resolveWorkerPython(req sharedruntime.PythonPathRequest) (string, error) {
	if devPython == "" {
		return sharedruntime.PythonPath(req)
	}
	// Never fall back to a stale bundle when a developer requests source mode.
	if !filepath.IsAbs(devPython) || sharedruntime.RuntimeRoot(devPython) != "" {
		return "", fmt.Errorf("devPython must be an absolute non-bundled interpreter path")
	}
	for _, path := range []string{devPython, filepath.Join(req.WorkerDir, "mcad_worker", "__main__.py"), filepath.Join(req.WorkerDir, "mcad", "__init__.py")} {
		info, err := os.Stat(path)
		if err != nil {
			return "", fmt.Errorf("development runtime: %w", err)
		}
		if info.IsDir() {
			return "", fmt.Errorf("development runtime: expected file at %s", path)
		}
	}
	return devPython, nil
}
