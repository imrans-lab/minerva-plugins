The manifest installs a source-built launcher, then prepares the pinned official
signed rc.18 payload before PluginManager can start it. Go and network access to
GitHub's official release hosts are needed on first setup. Installed receipt
matches are checked before network access; launcher startup never downloads.
The `.exe` build output is intentional on all platforms: Go `-o` preserves the
specified filename and generic setup resolves its exec path absolutely.

State and installs live under `shared/runtime.DataDir("docket")/official`, a
0700 child of the shared plugin data directory. Child Linux XDG and Windows
APPDATA/LOCALAPPDATA directories are private and absolute; HOME is preserved.
macOS bundle bytes remain signed and unchanged; Godot's engine cache/log paths
can still be shared there. Windows/macOS GUI ownership and shutdown need HITL.
No registry publication or change to host autostart/autoupdate defaults.

Independent Linux executor, exact candidate and GS host as siblings, verified
native extensions and Godot available, Go dependencies cached, Xvfb installed:

```bash
export MINERVA_PLUGIN_DATA_DIR=/absolute/fresh/scratch/docket-data
export MINERVA_DOCKET_PLUGIN_DIR=/absolute/scratch/minerva-plugins/docket
# Executor builds this binary; source authors compile but never execute it.
GOWORK=off go -C "$MINERVA_DOCKET_PLUGIN_DIR" build -o docket-plugin.exe .
# Optional OFFLINE fixture preparation: retained official assets + signatures.
DOCKET_RELEASE_FIXTURE=/absolute/official-rc18 DOCKET_STAGE_PLUGIN=1 \
  GOWORK=off go -C "$MINERVA_DOCKET_PLUGIN_DIR" test -run '^TestOfficialRelease$' -count=1 .
# Run after disabling network to prove installed offline restart.
# Without fixture staging, producer/setup need the official network on first use.
xvfb-run -a bash /absolute/scratch/minerva-plugins/scripts/run-gd-tests.sh \
  --plugin docket /absolute/scratch/Minerva
```

The executor must isolate host user data with fresh absolute XDG directories
before Godot starts; do not override HOME. Source checkout must be writable for
setup output/generated lifecycle-manifest.json. Missing binaries, fixtures,
natives or assertions fail. The oracle installs via the producer and real host
PluginManager, checks discovered names, mapped create/get calls, durable private
project writes across stop/restart, disabled autostart and dead child PIDs.
Docket's GUI maintains ownership; the launcher sends no heartbeat requests.
