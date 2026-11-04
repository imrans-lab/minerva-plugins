# T3 Code plugin — crawl

Experimental adapter for Codex through an existing official T3 Code installation. DCR: `experiment:01a14243aa897a5e8eacb7c3276d94cf`; T1: `experiment:01a1988d581579169ec001419dadd6c5`; T2: `experiment:01a1988d71157fe781761ae7287b8ad1`.

The source now includes the T1 runtime manager and T2 turn engine. **T2 remains incomplete:** one question-response recovery path can return an answer while its retained control receipt still says outcome unknown. This is an unaccepted source candidate, not live readiness. Source validation does not install/start T3, issue a real bearer or send a model request. Live execution remains behind the owner's T3/Node installation decision and the attended crawl gates.

## Identity and build

The directory and provider entry are `t3-code`; the manifest ID is `t3_code`, because Minerva permits underscores but rejects hyphens in plugin IDs. The provider key is `plugin:t3_code:t3-code`.

```sh
cd t3-code
cargo build --release --locked
cp target/release/t3-code-plugin t3-code-plugin
```

Install the built `manifest.json` through Minerva's normal local manifest lane. It has no setup script or first-use build. Do not install an unbuilt source directory. No T3 source or executable is bundled. Rust 1.89 or newer is required for the process writer lock. `Cargo.lock` pins dependencies; `ureq` supplies bounded HTTP with default TLS/compression/proxy features disabled. The public issuer JSON supplies session identity, scopes and ISO expiry; the bearer stays opaque.

Crawl targets Linux x86_64 and macOS arm64. Windows and macOS Intel are unsupported. A successful compilation is not platform acceptance; both supported platforms still need the T4 owner checks.

## Settings and prerequisites

Preferences has a **T3 Code** tab. Paths name existing executables; they are passed directly to the OS, never to a shell.

| Setting | Meaning |
| --- | --- |
| `t3_binary` | Existing native executable from a completed official T3 v0.1.6 CLI installation; launcher scripts are refused without execution. |
| `node_binary` | Host Node for child CLI shebangs. Native T3 bundles Node; its source-engine range is reported for information and does not gate this executable. |
| `codex_binary` | Existing Codex CLI. |
| `codex_home` | Explicit owner-approved login home, default `~/.codex`, used in place. Credentials are never copied, moved or deleted. |
| `t3_base_dir` | Empty private directory on first start, then retained plugin-owned T3 state; default `{private}/t3`. An unrelated existing T3 base is refused. |
| `t3_token_file` | Fresh private bearer-file path, default `{private}/mcp-token`, outside the T3 base and Codex home. Existing arbitrary files are refused; store a path, never a token, in preferences. |
| `minerva_mcp_endpoint` | Authorized Minerva MCP URL for the plugin-owned native Codex wiring in T2. No Core/UGS connection is used. |

`{private}` resolves to this plugin's per-user data directory (`$XDG_DATA_HOME/Minerva/plugins/t3_code` or `~/.local/share/Minerva/plugins/t3_code` on Linux; `~/Library/Application Support/Minerva/plugins/t3_code` on macOS). It is separate from the installed plugin. `{workspace}` is the folder of the saved `.minproj`; an unsaved project refuses. The owned runtime is pinned to the canonical saved-project folder selected at plugin start. A different current or chat-bound folder is held with both paths and a restart instruction; restart re-discovers that folder’s Codex MCP configuration. No project configuration is disabled to bypass this rule. `{minerva_mcp}` expands to the declared endpoint setting. The acceptance driver can supply absolute paths under its disposable root.

`minerva_t3_code_status(chat_id)` answers before the first turn. It returns the plugin-owned `thread_id`/`run_id`, bound folder and model, observed permission mode, client ceiling, prerequisite errors and compatibility tuple. Lifecycle states are `NO_INSTALL`, `INSTALLED`, `STARTING`, `READY`, `DEGRADED`, `STOPPING`, `CRASHED` and `DRIFT`. Status includes the last failure step, endpoint/epoch/session expiry, disabled MCP entry names, ownership mechanism and hard-kill limitation, never a bearer. Installation changes warn while a pinned server is running and refuse its next start. Detected versions are not editable preferences. T3 inspection only reads the resolved native header and adjacent `.install-complete` marker; it never executes an npm/installer launcher. Existing Node/Codex version and `codex login status` probes are bounded and use the selected home without logging their output. No prerequisite failure installs software or changes authentication/billing modes.

The entry declares `newest_only`, `resumable`, `interrupt_in_place`, generate and cancel tools. Generation and Stop require the host’s stable `operation_token`. Without an owned runtime, generation is held; Stop records its intent privately before every runtime/auth gate and reports no invented backend cancellation. While auth is being reissued, that intent prevents later submission. The Stop caller waits behind an ongoing reissue and then interrupts its exact bound run; failed renewal reports interruption unconfirmed and retains intent. Exact-run interruption uses the manager’s pinned settings even after the current project changes. Completed activity uses core’s generic `HcpData.activity[]` contract.

## Turn ownership and recovery

The plugin stores `chat_id → thread_id`, the canonical saved `.minproj` folder, durable base identity and run receipts under `{private}/chats`, outside disposable T3 state. The directory is 0700 and files are 0600, with one process writer lock and atomic, synced replacement. Receipts include private prompt/reply content and are retained; they are not a scrubbed trace. A chat receipt is bounded to16MiB and transcript reads to 32MiB; exceeding a bound refuses without presenting a partial transcript as final. Two chats bound to one folder share files. Changing the active project never moves an existing thread. Immediately before submission the adapter checks T3’s current project root/worktree, provider and mode against the saved binding and refuses changes. An unsaved project refuses a new chat and any setting that needs `{workspace}`; that token never collapses to a root path. The public protocol offers no atomic expected-folder precondition: an external T3 root change between verification and send remains an inherent race. Project verification pages the public catalog (bounded to 30 seconds); no cached root is treated as current proof.

Each launch/send stores its exact request and `clientRequestId` before submission, then stores the accepted `runId` before waiting. One safe retry reuses the same live MCP client/session, auth namespace and client ID. It is reachable through original-token resume or a later new message that triggers recovery of only the original receipt. New text receives an error with `held:true`, the prior operation token/run ID, and a named hold reason while a prior run is unfinished or unconfirmed. It never receives an old answer or pending reply as if its new text had been delivered. No host-token aliases are created. If the old run completed while the GUI was waiting, the gate saves its full settled final reply and shows a capped earlier-answer notice inside a held refusal (`delivered_via: held_notice`); the next message then proceeds. Original-token resume remains the internal pending-call mechanism. A known pre-dispatch refusal ends that unsubmitted attempt so a fresh message can proceed; a generic server error, or any refusal after an already unknown attempt, remains unconfirmed. After restart/reissue, an unknown outcome causes a public thread reread and a visible reconciliation refusal: the public read lacks the missing client receipt, so the plugin never guesses a run from matching text. Reconcile in T3 or start a fresh Minerva chat. A lost thread is reported as `thread_lost`; no history reconstruction or replacement thread is automatic.

Generation waits at most 2 seconds per backend wait and returns `pending` with the same host operation token. Resume only polls that receipt. Final answers reread the settled snapshot from the beginning, follow `hasMore`/`nextPosition`, and fetch every truncated item via its text offsets. Pages use 20 items × 8000 characters to fit the 8MiB HTTP response bound, with a distinct response_too_large refusal. Activity detail alone is capped to 4KiB with a visible truncation note; assistant text remains complete. Every item is filtered to the bound source thread and run; position cursors are never treated as an update feed. Snapshot requests have a 30-second aggregate read budget plus the bounded in-flight HTTP request. No incomplete read is a final answer.

Stop has an independent dispatch path. Submission rechecks intent after network verification and immediately before sending. Any recovered run receipt processes recorded Stop before returning, including recovery triggered by fresh input. It persists its operation-token intent before interrupting the exact returned run ID, including a Stop that arrives before the send receipt. It never uses `stop:true` or “latest run”, and `cancelled:true` requires T3 to report `cancelled` or `interrupted`.

A user-input card’s random opaque values live only in that chat’s stored pending request. The next message revalidates the request against the bound active run and public pending list/read. Wrong-chat, wrong-run, stale and ambiguous options refuse. Multiple questions are answered locally one at a time, then submitted once. Unknown outcomes from `respond` are reconciled without automatic resubmission because that tool has no client request ID. While the answer receipt is unknown, its stored and returned reply is pending with `state: outcome_unknown`; pending-list absence alone never proves acceptance. A terminal observation of the bound run replaces that pending reply with the terminal result, without claiming the answer was accepted. A concurrent resume reads only its own stored reply while another operation owns the chat; resume waits behind auth renewal through the same barrier as Stop. Permission requests produce a visible deferred error/activity card; this plugin never calls an approval tool. Deferral is not final: resume the original operation token to observe its bound run. A new message stays held while that run is active. A completed run is recovered once through the earlier-answer held notice, preserving its full reply privately; no GUI resume token is required. The new-send gate may retire a confirmed cancelled/failed run, recording its run ID and terminal state before accepting fresh text; it never substitutes an old answer. The accepted original prompt uses `held:false, deferred:true, hold_reason:permission_deferred`; a later new message held behind it uses `held:true`. Invalid options preserve the current question and partial answers. A fresh public pending-list proof of expiry retires the old card so original-token resume can observe the run. A definitely unsent question response retains/restores its pending question for an explicit answer after recovery. Only terminal results are permanently cached. Wake notifications use `t3_code.turn_completed` with `turn_completed`, `input_requested` or `thread_lost`, chat/thread/operation references only. The Phase B manager owns `agent_exited` when an owned process actually exits; a failed or cancelled run alone is a completed turn, not evidence of process exit. No transcript is posted to Docket.

## Preparing a launch-dialog session

Source candidate for DCR `minerva:01a1a2fe74de799eb1b9a4af86145bdd`, plugin batch only. Host dialog/picker work and live E2E acceptance follow separately. The W1 provider registration and its metadata are unchanged.

`minerva_t3_code_status({})` adds `launch_options` when no chat is supplied: `available`, canonical pinned `workspace`, `registered`, `harness`/`instance_id`, `runtime_mode`, `models` (`id`, `label`, `efforts`, `default_effort`, `effort_support`), `default` model selection and `default_error`. Only the owned Codex instance is offered. Capabilities may advertise a short list; `omitted_models` reports that limit. Missing effort descriptors produce null choices and `unverified`, never invented effort levels. Before readiness the options are unavailable and registration is unknown (null), not falsely unregistered. A stale or non-Codex project default is reported as null with an explanation; a listed model may still be chosen explicitly.

Model discovery can still be pending when the owned server is ready. A missing Codex instance, empty model list, or instance whose `canRunChildTask`/`constraints` report it unavailable returns held `capabilities_pending` with waiting and retry guidance; status includes the same code/text in `launch_options`. An ambiguous choice among several Codex instances retains `codex_unavailable`. The incomplete/unavailable snapshot is not cached. `RuntimeCache::get_ready` gates status launch options and launch; first-Generate model selection uses the same readiness rule. `RuntimeCache::get` provides non-gating transport access for Stop, recorded-operation resume/reconciliation, chat status and registration lookup. Each uncached lookup makes at most one new capabilities request, with no in-call loop, sleep or background retry. The existing HTTP bound is 8 seconds per request (an uncached client bootstrap uses four requests, at most 32 seconds of HTTP work, excluding lock/file overhead). A usable nonempty snapshot keeps the existing epoch/bearer cache. The first-empty cause is **unverified**: failed/logged-out discovery can also lack models, so an empty snapshot alone does not prove startup timing. Persistent waiting calls for checking the owned provider configuration. Authentication, transport and existing contract failures keep their distinct errors.

Call `minerva_t3_code_launch` with the new Minerva `chat_id` and optional advertised `model`/`effort`. The default is the project's advertised Codex selection, else the first advertised Codex model. Advertised default effort is explicit when available; otherwise the provider default is retained. The tool validates before any registration, uses the existing durable `Chat.model` field (no chat schema change), and confirms `model_selection`, `model`, `effort`, `harness`, `workspace`, `runtime_mode`, `display_name` and the registration result. No T3 thread or model request is created by this call. First Generate forwards the recorded selection into the existing lazy thread-launch path; old chats without a prepared selection keep their project-default behavior. Confirmed choices cannot be replaced, and a chat with any prior operation/thread must use a fresh session for new choices. Repeating the same preparation only rereads existing registration.

Launch is single-shot per chat: later calls can only reconfirm the same choices; changing them requires a new chat. JSON null for model or effort is treated as omission.

For an unregistered pinned folder, launch runs the public CLI `t3 project add --base-dir <owned-base> <pinned-workspace>` once, under the existing runtime manager and the owner's OS identity. The command is argument-based, never a shell, uses the owned environment/base, is bounded to30 seconds with private-process cleanup, and is cancelled on unload. Manager serialization rereads registration before invoking it, so another launch does not register the same folder twice. A failure is returned with its bounded CLI stdout/stderr; a successful CLI result is checked through the read-only public project list. No automatic retry follows failure or unknown output: read launch options before retrying. This is the Start action's registration effect; the later host dialog must name that exact folder and show the result/failure. Direct Generate still refuses an unregistered folder and does not register one.

The MCP bearer retains only orchestration read/operate scopes and its approval-required ceiling. It never creates a project. Credential issuer/revoke commands retain their existing output redaction; only the fixed public registration argv enables diagnostic capture. The plugin's own credentials are excluded by construction: no credential argument, inherited T3CODE_* controls stripped, and the plugin bearer file is never referenced by project-add. The pinned CLI mints its own internal session token (`cli/project.ts:406-417`); redaction of that upstream token in T3's failure text remains unverified. Combined stdout/stderr is capped at64KiB; failure diagnostics are shown only for registration. The real Codex home is never copied or edited by this feature.

Pinned source encoding: `ModelSelection.options` is an array of `{id, value}` (`packages/contracts/src/modelSelection.ts:9-13`, `model.ts:49-52`); capabilities advertise `{id, values, default}` (`orchestratorMcp.ts:582-602`). `CodexAdapterV2.ts:761-765` reads `reasoningEffort` at thread launch. The new nested dependency is documented in `t3-contract.json`; its top-level eight-tool probe is unchanged. Model/effort propagation, CLI registration and the eventual header are **live-unverified** until E2E D3/D4 and the owner gates. Source validation performs no T3 execution, auth issuance, model turn or owner-profile mutation.

## Owned runtime boundary and native Minerva tools

Only the T1 manager writes/retires `{private}/owned-runtime.json`; schema 2 is defined once in `src/runtime.rs`. The receipt records endpoint, per-spawn epoch, durable base identity, session/expiry, base, token path, selected and resolved Codex executable, home, launch arguments, disabled MCP entries, canonical project folder and ownership mechanism. T2 consumes it; an arbitrary endpoint is never adopted. Generate cannot start/restart a server. It can request one public auth reissue from `DEGRADED`, creating a new idempotency namespace. Accepted/unknown operations retain their previous namespace and are not blindly replayed. Ordinary restart preserves the base identity (claimed base instance, canonical base/token/folder tuple) and chat map while replacing the server epoch and auth namespace. A retained bound thread is publicly revalidated before another send; an unknown old-namespace operation is reread and held for reconciliation.

Plugin initialization checks prerequisites, claims a private base with a locked ownership marker, discovers the effective Codex MCP inventory through public `mcp list --json` and `mcpServerStatus/list`, and configures the private T3 settings before starting `t3 serve --mode web --host 127.0.0.1 --port <chosen> --no-browser`. Discovery creates no thread or model turn. Every configured entry targeting the Minerva endpoint/port or exposing a `minerva_` tool is disabled with process-local per-key `enabled=false` overrides; unusual entry names refuse rather than assume quoted-key parsing; all other MCP entries and provider/model routing remain in force. Transient starting/notStarted entries are polled within the discovery deadline. Incomplete inventory or an unproven plugin-provided disable path refuses startup visibly.

T3 uses `setupMode: existing`, the resolved existing Codex binary, the real selected home, an empty `shadowHomePath` and explicit launch arguments. `CODEX_HOME` stays in place. The checked Node directory leads the child PATH. The native `minerva_t3_crawl` HTTP MCP entry has only `enabled_tools = ["minerva_list_chats"]` and required startup. No real Codex config file is edited, no credential home is copied, and no UGS/Core route is used. Codex can read and refresh its existing login normally. The public T3 thread override preserves other launch MCP entries (pinned `CodexAdapterV2.ts:1354`). See [Codex MCP configuration](https://developers.openai.com/codex/mcp/) for per-entry enablement and tool allowlists.

The owned environment sets `T3CODE_TELEMETRY_ENABLED=false`, removes inherited T3/OTel and service-launcher controls, and uses the unmanaged web server mode without desktop bootstrap or service self-update. Private settings disable provider update checks and automatic continuation. Public `t3 connect unlink --base-dir <owned>` clears Connect before serve starts. The plugin never calls reset-credit consumption; its MCP credential has only orchestration read/operate scopes, not the provider-write route. These are source-established boundaries; their live behavior remains to be observed.

Owned child processes use umask 077; the parent’s umask is unchanged. The manager captures serve output in a new private 0600 log because startup can print pairing material. It issues the public mcp-client session, writes the token before the receipt, and validates the owned server's public tool catalog before `READY`. Expiry/401 changes the manager to `DEGRADED`; the stale receipt is retained while the server remains owned. EOF or trapped SIGTERM/SIGINT revokes the session, retires token/receipt and stops the owned process tree. Unexpected serve exit retires its epoch, reports the actual exit, wakes active chats and does not restart the server. Chat maps and T3 state survive unload.

Linux prefers an epoch-named transient systemd user scope. T3's own systemd relocation is disabled for that process. When unavailable, Linux uses a reserved process group and birth-checked tracked-PID sweeps; macOS uses that same **best-effort** fallback. Status reports the actual mechanism. No process is killed by name or adopted from a saved PID.

**Hard plugin kill is a marked crawl limitation.** SIGKILL cannot run Rust cleanup. Linux direct-child parent-death SIGTERM and next-start cleanup of the exact saved owned scope mitigate it; they do not prove every descendant was reaped. On macOS/fallback, restart can revoke/retire the stale credential and receipt but cannot safely kill a saved PID. Stale T3 runtime records alone do not block restart; T3’s own ownership lock refuses an already-live server, which then requires reconciliation. A kill before a credential receipt exists can also leave a token path requiring reconciliation. T4 must mark this case and prove ordinary stop/restart cleanup on real hardware; a separate supervisor is deferred.

HTTP is explicit loopback IP only, without redirects, environment proxy, remote URLs or credentials in diagnostics. The embedded dependency set is checked against the owned server’s public `tools/list` before turn submission. Native MCP login/tool delivery and all real crawl rows remain unproven until the owner-attended Phase B run.

## Authentication source spike

Pinned upstream: [v0.1.6](https://github.com/pingdotgg/t3code/releases/tag/v0.1.6), commit `2359643cffa6ba9ee84d6f2694b935de54a8013e`. The source result is T1 comment 13; live proof is pending the owner's installation decision.

The public `t3 auth session issue` CLI accepts `--subject mcp-client`, repeated `--scope orchestration:read --scope orchestration:operate`, explicit `--base-dir`, `--ttl 1h`, `--label` and `--json`. This yields the bearer audience accepted by `/mcp`; its default subject does not. No private server-module import or T3 patch is needed.

This issuance path has an **approval-required ceiling**. It cannot grant full access. T3 requires full access to register a project. The launch-dialog preparation tool uses the public `t3 project add --base-dir <owned-base> <saved-folder>` CLI for the exact startup-pinned folder, as described above. The MCP bearer never registers projects or raises its access. Direct Generate still requires prior registration and otherwise refuses with a copyable command. Every launch explicitly supplies `runtimeMode: "approval-required"`, per Claude’s T2 ruling5524. Pinned T3 otherwise silently narrows an incompatible project default to the client ceiling; the plugin does not claim to preserve that unobservable default. The observed thread mode is recorded and shown, and a later incompatible change refuses a new send. Approval handling is deferred to walk; crawl must show a permission deferral and execute nothing rather than broaden a sandbox to avoid the request.

The manager captures issuance JSON privately, puts only the raw bearer in the configured file with mode 0600, and keeps the session ID/expiry privately for `t3 auth session revoke --base-dir <same-base> <session-id>`. Sessions default to 30 days upstream; the owned session uses one hour. There is no refresh token on this CLI path: re-authentication creates a new session and idempotency namespace, so an accepted or unknown send must not be replayed blindly. Session identity, scopes and the canonical UTC `expiresAt` value come from the public issuer JSON. The bearer stays opaque. No issuance/revocation is executed during source validation.

T3 retains its database, provider logs, attachments, secrets and checkpoints under its private base. These can contain sensitive content and outlive a thread. Only the separately scrubbed acceptance trace is secret-free. Controlled unload must revoke the owned bearer and clean up the owned T3/Codex process tree; crash/expiry and lifecycle proof belong to Phase B. Unrelated processes and the real Codex login must remain intact.

## Public-contract drift probe

`t3-contract.json` is the single stored dependency list shared with T2 (comment 14). The validator checks only the tools/input properties used by this adapter, and rejects newly required arguments outside the supplied field set. A supplied field becoming required is compatible. The pinned schema-required baseline is source-cited documentary metadata, not the compatibility whitelist. Extra tools and optional properties are accepted. Startup consumes the owned server’s `tools/list` before publishing readiness; status distinguishes the source-only candidate from observed runtime state. No live probe was run during source validation.

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
