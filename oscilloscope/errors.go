// SPDX-License-Identifier: GPL-3.0-or-later
package main

import (
	"context"
	"errors"
	"github.com/google/gousb"
	"strings"
)

type ToolError struct {
	Code      string `json:"code"`
	Message   string `json:"message"`
	Retryable bool   `json:"retryable"`
	Action    string `json:"suggested_action"`
}

func (e *ToolError) Error() string { return e.Message }
func fault(code, message string, retry bool, action string) *ToolError {
	return &ToolError{code, message, retry, action}
}
func invalid(message string) *ToolError {
	return fault("INVALID_ARGUMENT", message, false, "Correct the arguments using tools/list.")
}
func toolError(err error) *ToolError {
	var t *ToolError
	if errors.As(err, &t) {
		return t
	}
	switch {
	case errors.Is(err, context.DeadlineExceeded), errors.Is(err, gousb.ErrorTimeout):
		return fault("ACQUISITION_TIMEOUT", err.Error(), true, "Check the USB connection, then retry capture.")
	case errors.Is(err, gousb.ErrorNoDevice):
		return fault("USB_DISCONNECTED", err.Error(), false, "Reconnect the scope, then run or capture.")
	case errors.Is(err, gousb.ErrorBusy):
		return fault("DEVICE_BUSY", err.Error(), false, "Close other scope applications, then retry.")
	case errors.Is(err, gousb.ErrorAccess):
		return fault("PERMISSION_DENIED", err.Error(), false, "Check device access permissions; on Linux install the USB access rules.")
	case strings.Contains(err.Error(), "not found"):
		return fault("DEVICE_NOT_FOUND", err.Error(), false, "Connect the scope USB data cable.")
	case strings.Contains(err.Error(), "unsupported scope firmware"):
		return fault("UNSUPPORTED_FIRMWARE", err.Error(), false, "Unplug and reconnect the scope to load bundled RAM firmware.")
	default:
		return fault("USB_ERROR", err.Error(), false, "Check the scope connection and inspect the error before retrying.")
	}
}
