The manifest installs a source-built launcher, then prepares the pinned official
signed rc.23 payload before PluginManager can start it. Go and network access to
GitHub's official release hosts are needed on first setup. Installed receipt
matches are checked before network access; launcher startup never downloads.
The `.exe` build output is intentional on all platforms: Go `-o` preserves the
specified filename and generic setup resolves its exec path absolutely.

State and installs live under `shared/runtime.DataDir("docket")/official`, a
0700 child of the shared plugin data directory. Dedicated Docket state is `official/state`; `child.pid` and `child-env` are
siblings, outside that state. Child Linux XDG and Windows
APPDATA/LOCALAPPDATA directories are private and absolute; HOME and inherited
XDG_RUNTIME_DIR are preserved for Wayland, PipeWire and D-Bus.
macOS bundle bytes remain signed and unchanged; Godot's engine cache/log paths
can still be shared there. Windows/macOS GUI ownership and shutdown need HITL.
Hosted Minerva leaves the `minerva_docket_*` names to this plugin and receives
its `item_changed` events through the generic broker. The registry still refuses
collisions with any remaining built-in names; the lifecycle oracle checks that
refusal separately. No registry publication.

The production manifest declares `docket_panel_v1` and passes `--host-authority`.
PluginManager supplies a fresh `DOCKET_PANEL_SECRET` for each child; the launcher
forwards it only in the child environment. No token is stored or passed in argv.
No-argument standalone stdio and acquisition/CLI modes remain available.
The bridge oracle closes the isolated embedded owner before DocketHost declares
Minerva schema and opens the canonical master; it checks private authentication,
rotation and old-token refusal without creating or initializing a vault.

Authorized writer or independent Linux executor, exact candidate and GS host as siblings, verified
native extensions and Godot available, Go dependencies cached, Xvfb installed:

```bash
export MINERVA_PLUGIN_DATA_DIR=/absolute/fresh/scratch/docket-data
export MINERVA_DOCKET_PLUGIN_DIR=/absolute/scratch/minerva-plugins/docket
# Build and execute only in the approved isolated planned job.
GOWORK=off go -C "$MINERVA_DOCKET_PLUGIN_DIR" build -o docket-plugin.exe .
# Optional OFFLINE fixture preparation: retained official assets + signatures.
DOCKET_RELEASE_FIXTURE=/absolute/official-rc23 DOCKET_STAGE_PLUGIN=1 \
  GOWORK=off go -C "$MINERVA_DOCKET_PLUGIN_DIR" test -run '^TestOfficialRelease$' -count=1 .
# Run after disabling network to prove installed offline restart.
# Without fixture staging, producer/setup need the official network on first use.
MINERVA_TEST_DISPLAY=test_docket_post_lifecycle_consumers.gd xvfb-run -a bash /absolute/scratch/minerva-plugins/scripts/run-gd-tests.sh \
  --plugin docket /absolute/scratch/Minerva
```

Use the two scratch variables above and fresh absolute XDG directories before
Godot starts; preserve HOME. Setup needs a writable checkout for its binary and
lifecycle manifest. Missing prerequisites and assertions fail. The oracle installs via the producer and real host
PluginManager, checks discovered names, mapped create/get calls, durable private
project writes across stop/restart, disabled autostart and dead child PIDs.
Docket's GUI maintains ownership; the launcher sends no heartbeat requests.

Healthy busy input may block; observed EOF/write errors start an eight-second reap bound.
If backpressure hides EOF, Minerva terminates the launcher after ten seconds, closing child pipes.
