package bridge

import (
	"strings"
	"testing"
)

func TestBuildEnvForwardsOnlyDesktopCaptureVariables(t *testing.T) {
	t.Setenv("DISPLAY", ":9")
	t.Setenv("XAUTHORITY", "/tmp/auth")
	t.Setenv("WAYLAND_DISPLAY", "wayland-3")
	t.Setenv("DBUS_SESSION_BUS_ADDRESS", "secret-bus")
	joined := strings.Join(buildEnv("python3"), "\n")
	for _, want := range []string{
		"DISPLAY=:9", "XAUTHORITY=/tmp/auth", "WAYLAND_DISPLAY=wayland-3",
	} {
		if !strings.Contains(joined, want) {
			t.Fatalf("missing %s in worker environment", want)
		}
	}
	if strings.Contains(joined, "DBUS_SESSION_BUS_ADDRESS") {
		t.Fatal("unexpected desktop session variable leaked into worker environment")
	}
}
