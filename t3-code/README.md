# T3 Code plugin — crawl

Experimental adapter for Codex through an existing official T3 Code installation. DCR: `experiment:01a14243aa897a5e8eacb7c3276d94cf`; T1: `experiment:01a1988d581579169ec001419dadd6c5`.

Phase A implements the plugin shell and prerequisite diagnostics. It registers one provider and **refuses every generation** with a visible `runtime_not_started` error. It starts no T3 server or agent, issues no bearer, and sends no model request. Live authentication, process ownership and turn delivery remain Phase B/T2. The owner decides when and how to install T3 and a suitable Node version.

## Identity and build

The directory and provider entry are `t3-code`; the manifest ID is `t3_code`, because Minerva permits underscores but rejects hyphens in plugin IDs. The provider key is `plugin:t3_code:t3-code`.

```sh
cd t3-code
cargo build --release --locked
cp target/release/t3-code-plugin t3-code-plugin
```

Install the built `manifest.json` through Minerva's normal local manifest lane. It has no setup script or first-use build. Do not install an unbuilt source directory. No T3 source or executable is bundled. `Cargo.lock` pins the small Rust plugin's dependencies.

Crawl targets Linux x86_64 and macOS arm64. Windows and macOS Intel are unsupported. A successful compilation is not platform acceptance; both supported platforms still need the T4 owner checks.

## Settings and prerequisites

Preferences has a **T3 Code** tab. Paths name existing executables; they are passed directly to the OS, never to a shell.

| Setting | Meaning |
| --- | --- |
| `t3_binary` | Existing native executable from a completed official T3 v0.1.6 CLI installation; launcher scripts are refused without execution. |
| `node_binary` | Node satisfying `^22.16 || ^23.11 || >=24.10`. |
| `codex_binary` | Existing Codex CLI. |
| `codex_home` | Explicit owner-approved login home, default `~/.codex`, used in place. Credentials are never copied, moved or deleted. |
| `t3_base_dir` | Private retained T3 state, default `{private}/t3`. |
| `t3_token_file` | Private bearer-file path, default `{private}/mcp-token`; store a path, never a token, in preferences. |
| `minerva_mcp_endpoint` | Authorized Minerva MCP URL for the plugin-owned native Codex wiring in T2. No Core/UGS connection is used. |

`{private}` resolves to this plugin's per-user data directory (`$XDG_DATA_HOME/Minerva/plugins/t3_code` or `~/.local/share/Minerva/plugins/t3_code` on Linux; `~/Library/Application Support/Minerva/plugins/t3_code` on macOS). It is separate from the installed plugin. `{workspace}` is the folder of the saved `.minproj`; an unsaved project refuses. `{minerva_mcp}` expands to the declared endpoint setting. The acceptance driver can supply absolute paths under its disposable root.

`minerva_t3_code_status(chat_id)` returns `state: not-started`, `ready: false`, empty `thread_id`, `run_id` and `endpoint`, prerequisite errors, and an authoritative `compatibility` tuple. Static supported values appear in settings help; detected versions are not editable preferences. Phase A reads the resolved native T3 file header and adjacent `.install-complete` version marker without executing any T3 code. An npm/installer launcher or incomplete installation refuses with a copyable prerequisite error: even `t3 --version` can otherwise install a runtime. The detected T3 version is explicitly labelled as marker-derived. Existing Node/Codex version and `codex login status` probes are bounded and use the selected Codex home; they do not log command output or credentials. A prerequisite failure never triggers an installer or changes authentication/billing modes.

The entry declares `newest_only`, `resumable`, `interrupt_in_place`, generate and cancel tools. Phase A accepts no operation; cancel truthfully returns `cancelled: false, state: not-started`. Completed activity later uses core's generic `HcpData.activity[]` contract, with no T3 UI branch.

## Authentication source spike

Pinned upstream: [v0.1.6](https://github.com/pingdotgg/t3code/releases/tag/v0.1.6), commit `2359643cffa6ba9ee84d6f2694b935de54a8013e`. The source result is T1 comment 13; live proof is pending the owner's installation decision.

The public `t3 auth session issue` CLI accepts `--subject mcp-client`, repeated `--scope orchestration:read --scope orchestration:operate`, explicit `--base-dir`, `--ttl 1h`, `--label` and `--json`. This yields the bearer audience accepted by `/mcp`; its default subject does not. No private server-module import or T3 patch is needed.

This issuance path has an **approval-required ceiling**. It cannot grant full access. Preserve project-default permission semantics and refuse an incompatible mode visibly. Approval handling is deferred to walk; crawl must show a permission deferral and execute nothing rather than broaden a sandbox to avoid the request.

Phase B must capture issuance JSON privately, put only the raw bearer in the configured file with mode 0600, and keep the session ID/expiry privately for `t3 auth session revoke --base-dir <same-base> <session-id>`. Sessions default to 30 days upstream; the proposed owned session uses one hour. There is no refresh token on this CLI path: re-authentication creates a new session and idempotency namespace, so an accepted or unknown send must not be replayed blindly. None of this issuance/revocation is executed by Phase A.

T3 retains its database, provider logs, attachments, secrets and checkpoints under its private base. These can contain sensitive content and outlive a thread. Only the separately scrubbed acceptance trace is secret-free. Controlled unload must revoke the owned bearer and clean up the owned T3/Codex process tree; crash/expiry and lifecycle proof belong to Phase B. Unrelated processes and the real Codex login must remain intact.

## Public-contract drift probe

`t3-contract.json` is the single stored dependency list shared with T2 (comment 14). The validator checks only the tools/input properties used by this adapter, and rejects new required arguments. Extra tools and optional properties are accepted. The normal startup probe will consume the owned server's `tools/list` in Phase B; status explicitly reports that no live probe ran in Phase A.

For an existing authorized `tools/list` JSON export, the same validator is available as a diagnostic command, without starting T3:

```sh
./t3-code-plugin --check-catalog /absolute/path/tools-list.json
```

This is a compatibility check, not proof of a running backend or successful turns.

## Acceptance

`e2e/crawl.py` is the single owner-attended crawl E2E, authored before implementation. Its defaults use `plugin_id: "t3_code"` and `entry_id: "t3-code"`; supply the built manifest path. The optional identity override remains available for alternate packaging. Missing runtime prerequisites do not count as localized row reds. No additional tests or CI lane are introduced in this stage.

The later crawl observes a real answer, persisted/rendered activity, one scoped read-only native Minerva tool, truthful permission deferral, exact-run UI Stop, settled transcript agreement and pending/host resume. Restart/lost-thread/lifecycle and platform UX remain owner gates. Crawl delivers at turn level; approvals, token streaming, a bundled runtime, Windows, Core/UGS and fleet operation are deferred.

## T3 attribution

[T3 Code](https://github.com/pingdotgg/t3code) is maintained by T3 Tools Inc. No T3 code is copied or distributed by this crawl plugin. Upstream's MIT notice at the pinned tag follows:

```text
MIT License

Copyright (c) 2026 T3 Tools Inc.

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
```
