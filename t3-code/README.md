# T3 Code plugin — crawl

Experimental adapter for Codex through an existing official T3 Code installation. DCR: `experiment:01a14243aa897a5e8eacb7c3276d94cf`; T1: `experiment:01a1988d581579169ec001419dadd6c5`; T2: `experiment:01a1988d71157fe781761ae7287b8ad1`.

T1 Phase A supplies the plugin shell and prerequisites. T2 adds the source turn engine, which remains **held without the Phase B manager’s owned runtime receipt**. This candidate does not create that receipt, start T3, issue a bearer or send a model request during source validation. The owner decides when and how to install T3 and a suitable Node version. Live authentication, lifecycle and real turn acceptance remain Phase B.

## Identity and build

The directory and provider entry are `t3-code`; the manifest ID is `t3_code`, because Minerva permits underscores but rejects hyphens in plugin IDs. The provider key is `plugin:t3_code:t3-code`.

```sh
cd t3-code
cargo build --release --locked
cp target/release/t3-code-plugin t3-code-plugin
```

Install the built `manifest.json` through Minerva's normal local manifest lane. It has no setup script or first-use build. Do not install an unbuilt source directory. No T3 source or executable is bundled. Rust 1.89 or newer is required for the process writer lock. `Cargo.lock` pins dependencies; `ureq` supplies bounded HTTP with default TLS/compression/proxy features disabled, rather than a handwritten HTTP parser.

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

`minerva_t3_code_status(chat_id)` answers before the first turn. It returns the plugin-owned `thread_id`/`run_id`, bound folder and model, observed permission mode, client ceiling, prerequisite errors and compatibility tuple. Without a manager receipt it reports `not-started`, `ready: false` and no endpoint. Detected versions are not editable preferences. T3 inspection only reads the resolved native header and adjacent `.install-complete` marker; it never executes an npm/installer launcher. Existing Node/Codex version and `codex login status` probes are bounded and use the selected home without logging their output. No prerequisite failure installs software or changes authentication/billing modes.

The entry declares `newest_only`, `resumable`, `interrupt_in_place`, generate and cancel tools. Generation and Stop require the host’s stable `operation_token`. Without an owned runtime, generation is held; Stop records its intent privately and reports no invented backend cancellation. Completed activity uses core’s generic `HcpData.activity[]` contract.

## Turn ownership and recovery

The plugin stores `chat_id → thread_id`, the canonical saved `.minproj` folder, state epoch and run receipts under `{private}/chats`, outside disposable T3 state. The directory is 0700 and files are 0600, with one process writer lock and atomic, synced replacement. Receipts include private prompt/reply content and are retained; they are not a scrubbed trace. A chat receipt is bounded to16MiB and transcript reads to 32MiB; exceeding a bound refuses without presenting a partial transcript as final. Two chats bound to one folder share files. Changing the active project never moves an existing thread. Immediately before submission the adapter checks T3’s current project root/worktree, provider and mode against the saved binding and refuses changes. An unsaved project refuses a new chat and any setting that needs `{workspace}`; that token never collapses to a root path. The public protocol offers no atomic expected-folder precondition: an external T3 root change between verification and send remains an inherent race. Project verification pages the public catalog (bounded to 30 seconds); no cached root is treated as current proof.

Each launch/send stores its exact request and `clientRequestId` before submission, then stores the accepted `runId` before waiting. One safe retry reuses the same live MCP client/session, auth namespace and client ID. It is reachable through original-token resume or a later new message that triggers recovery of only the original receipt. New text always receives an error with `held:true`, the prior operation token/run ID, and a named hold reason while a prior run is unfinished or unconfirmed. It never receives an old answer or pending reply in place of delivery. Observe a prior run only by resuming its original token; no host-token aliases are created. A known pre-dispatch refusal ends that unsubmitted attempt so a fresh message can proceed; a generic server error, or any refusal after an already unknown attempt, remains unconfirmed. After restart/reissue, an unknown outcome causes a public thread reread and a visible reconciliation refusal: the public read lacks the missing client receipt, so the plugin never guesses a run from matching text. Reconcile in T3 or start a fresh Minerva chat. A lost thread is reported as `thread_lost`; no history reconstruction or replacement thread is automatic.

Generation waits at most 2 seconds per backend wait and returns `pending` with the same host operation token. Resume only polls that receipt. Final answers reread the settled snapshot from the beginning, follow `hasMore`/`nextPosition`, and fetch every truncated item via its text offsets. Pages use 20 items × 8000 characters to fit the 8MiB HTTP response bound, with a distinct response_too_large refusal. Activity detail alone is capped to 4KiB with a visible truncation note; assistant text remains complete. Every item is filtered to the bound source thread and run; position cursors are never treated as an update feed. Snapshot requests have a 30-second aggregate read budget plus the bounded in-flight HTTP request. No incomplete read is a final answer.

Stop has an independent dispatch path. It persists its operation-token intent before interrupting the exact returned run ID, including a Stop that arrives before the send receipt. It never uses `stop:true` or “latest run”, and `cancelled:true` requires T3 to report `cancelled` or `interrupted`.

A user-input card’s random opaque values live only in that chat’s stored pending request. The next message revalidates the request against the bound active run and public pending list/read. Wrong-chat, wrong-run, stale and ambiguous options refuse. Multiple questions are answered locally one at a time, then submitted once. Unknown outcomes from `respond` are reconciled without automatic resubmission because that tool has no client request ID. Permission requests produce a visible deferred error/activity card; this plugin never calls an approval tool. Deferral is not final: resume the original operation token to observe its bound run. A new message is held until that observation settles a completed/deferred run. The new-send gate may retire a confirmed cancelled/failed run, recording its run ID and terminal state before accepting fresh text; it never substitutes an old answer. The accepted original prompt uses `held:false, deferred:true, hold_reason:permission_deferred`; a later new message held behind it uses `held:true`. Invalid options preserve the current question and partial answers. A fresh public pending-list proof of expiry retires the old card so original-token resume can observe the run. A definitely unsent question response retains/restores its pending question for an explicit answer after recovery. Only terminal results are permanently cached. Wake notifications use `t3_code.turn_completed` with `turn_completed`, `input_requested` or `thread_lost`, chat/thread/operation references only. The Phase B manager owns `agent_exited` when an owned process actually exits; a failed or cancelled run alone is a completed turn, not evidence of process exit. No transcript is posted to Docket.

## Owned runtime boundary and native Minerva tools

Only the future T1 Phase B manager writes/retires `{private}/owned-runtime.json`. T2 only reads its 0600 receipt and bearer file; there is no arbitrary endpoint preference or automatic runtime adoption. The manager must establish process ownership, pin the install, revoke on controlled unload and rotate the epoch when disposable T3 state is replaced. Missing/expired/mismatched receipts hold generation. Receipt schema is defined once in `src/runtime.rs` and recorded on T2; a receipt is source plumbing, not live acceptance evidence.

The manager passes `CODEX_HOME` in place and `T3CODE_CODEX_LAUNCH_ARGS` generated by `runtime::codex_launch_args` to its owned T3 process. Those arguments configure a native Codex HTTP MCP entry `minerva_t3_crawl` with the authorized `{minerva_mcp}` endpoint, `enabled_tools = ["minerva_list_chats"]`, and required startup. No real Codex config file is edited, no credential home is copied, and no UGS/Core route is used. Existing owner configuration remains in force; the only Minerva tool introduced by this entry is the scoped read-only chat list. The public T3 thread override preserves other launch MCP entries (pinned `CodexAdapterV2.ts:1354`). See [Codex MCP configuration](https://learn.chatgpt.com/docs/extend/mcp?surface=cli) for `enabled_tools`.

HTTP is explicit loopback IP only, without redirects, environment proxy, remote URLs or credentials in diagnostics. The embedded dependency set is checked against the owned server’s public `tools/list` before turn submission. Native MCP login/tool delivery and all real crawl rows remain unproven until the owner-attended Phase B run.

## Authentication source spike

Pinned upstream: [v0.1.6](https://github.com/pingdotgg/t3code/releases/tag/v0.1.6), commit `2359643cffa6ba9ee84d6f2694b935de54a8013e`. The source result is T1 comment 13; live proof is pending the owner's installation decision.

The public `t3 auth session issue` CLI accepts `--subject mcp-client`, repeated `--scope orchestration:read --scope orchestration:operate`, explicit `--base-dir`, `--ttl 1h`, `--label` and `--json`. This yields the bearer audience accepted by `/mcp`; its default subject does not. No private server-module import or T3 patch is needed.

This issuance path has an **approval-required ceiling**. It cannot grant full access. Every launch explicitly supplies `runtimeMode: "approval-required"`, per Claude’s T2 ruling5524. Pinned T3 otherwise silently narrows an incompatible project default to the client ceiling; the plugin does not claim to preserve that unobservable default. The observed thread mode is recorded and shown, and a later incompatible change refuses a new send. Approval handling is deferred to walk; crawl must show a permission deferral and execute nothing rather than broaden a sandbox to avoid the request.

Phase B must capture issuance JSON privately, put only the raw bearer in the configured file with mode 0600, and keep the session ID/expiry privately for `t3 auth session revoke --base-dir <same-base> <session-id>`. Sessions default to 30 days upstream; the proposed owned session uses one hour. There is no refresh token on this CLI path: re-authentication creates a new session and idempotency namespace, so an accepted or unknown send must not be replayed blindly. None of this issuance/revocation is executed by Phase A.

T3 retains its database, provider logs, attachments, secrets and checkpoints under its private base. These can contain sensitive content and outlive a thread. Only the separately scrubbed acceptance trace is secret-free. Controlled unload must revoke the owned bearer and clean up the owned T3/Codex process tree; crash/expiry and lifecycle proof belong to Phase B. Unrelated processes and the real Codex login must remain intact.

## Public-contract drift probe

`t3-contract.json` is the single stored dependency list shared with T2 (comment 14). The validator checks only the tools/input properties used by this adapter, and rejects newly required arguments outside the supplied field set. A supplied field becoming required is compatible. The pinned schema-required baseline is source-cited documentary metadata, not the compatibility whitelist. Extra tools and optional properties are accepted. The normal startup probe will consume the owned server's `tools/list` in Phase B; status explicitly reports that no live probe ran in Phase A.

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
