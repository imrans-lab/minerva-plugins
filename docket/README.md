The manifest installs a source-built one-shot launcher, then prepares the pinned
signed official Docket payload. Go and access to GitHub's official release hosts
are needed on first setup. Launcher startup never downloads. The `.exe` output
name is intentional on every platform.

Docket owns its standalone Godot `app_userdata/Docket` profile and `instance.json`.
The launcher attaches to a registered live PID answering HTTP on loopback, or
starts the verified installed payload with `--quiet` in a new session (Unix) or
detached process group (Windows). It inherits the environment without profile
redirection. The old plugin-private state is left on disk without migration.

The launcher prints one JSON status line: `attached` or `spawned`, with `pid`,
`endpoint` and the registered `version`. It exits 0, leaving Docket alive. If no
live HTTP registration appears within 30 seconds, it kills only its own spawned
PID and exits 2 with `status: failed` and `reason`. Minerva connects over HTTP;
closing Minerva does not stop Docket.

Verified payloads remain under `shared/runtime.DataDir("docket")/official` or
beside the launcher in marketplace archives. A live registered instance is selected before installation-root, platform or
receipt checks, and its live version is reported. Only spawning requires the
installed verified payload. The setup `prepare` operation and signed acquisition
checks are unchanged; setup-time gating while Docket runs is outside this launch
contract. Windows/macOS lifetime behavior needs
native acceptance checks.

Required-plugin releases use Minerva's existing `plugin-release.yml` lane.
Marketplace archives contain the source-built launcher and verified payload.
Wrapper-only versions append `.plugin.N`; the signed upstream tag stays pinned.
