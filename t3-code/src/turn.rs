//! Project/model selection and exact-run observation over the public tools.

use crate::{
    fault::{string, Fault, Result},
    runtime::Runtime,
    snapshot::Snapshot,
    storage::{Chat, Operation},
};
use serde_json::{json, Value};
use std::collections::BTreeSet;

pub fn select_project(runtime: &Runtime, workspace: &str) -> Result<(String, Value)> {
    let providers = runtime.capabilities["providers"]
        .as_array()
        .ok_or_else(|| Fault::new("contract_mismatch", "T3 capabilities omitted providers."))?;
    let codex: Vec<&Value> = providers
        .iter()
        .filter(|p| p["driverKind"] == "codex")
        .collect();
    let provider = if let Some(default) = codex.iter().find(|p| p["providerInstanceId"] == "codex")
    {
        *default
    } else if codex.len() == 1 {
        codex[0]
    } else {
        return Err(Fault::held("codex_unavailable", "T3 has no unambiguous Codex provider. Configure the existing Codex login in T3; no other provider or billing mode is selected."));
    };
    let instance = string(provider, "providerInstanceId")?;
    let model = provider["models"]
        .as_array()
        .and_then(|models| models.first())
        .and_then(|m| m["id"].as_str())
        .ok_or_else(|| {
            Fault::held(
                "codex_unavailable",
                "T3 advertised no available Codex model.",
            )
        })?;
    let fallback = json!({"instanceId":instance,"model":model});
    let mut found = find_projects(runtime, "workspaceRoot", workspace)?;
    if found.len() > 1 {
        return Err(Fault::held(
            "project_ambiguous",
            "Multiple T3 projects share this folder. Resolve them in T3 before starting a chat.",
        ));
    }
    let project = if let Some(project) = found.pop() {
        project
    } else {
        // The public CLI issuer caps this client at approval-required. T3
        // requires full access to register projects, so the owner does it once.
        return Err(Fault::held(
            "project_unregistered",
            format!(
                "No prompt was sent. Register this saved folder in T3 once, then retry:\nt3 project add --base-dir '{}' '{}'",
                runtime.receipt.base_dir.replace('\'', "'\"'\"'"),
                workspace.replace('\'', "'\"'\"'")
            ),
        ));
    };
    let selected = &project["defaultModelSelection"];
    let selection = if selected.is_null() {
        fallback
    } else {
        let id = string(selected, "instanceId")?;
        let selected_model = string(selected, "model")?;
        if !codex.iter().any(|p| {
            p["providerInstanceId"] == id
                && p["models"]
                    .as_array()
                    .is_some_and(|models| models.iter().any(|m| m["id"] == selected_model))
        }) {
            return Err(Fault::held("codex_unavailable","This T3 project's default selection is not an available Codex model. Choose its default in T3; the plugin will not replace it."));
        }
        selected.clone()
    };
    Ok((string(&project, "id")?.to_owned(), selection))
}

fn find_projects(runtime: &Runtime, field: &str, value: &str) -> Result<Vec<Value>> {
    let mut args = json!({"limit":100});
    let mut cursors = BTreeSet::new();
    let mut found = Vec::new();
    let deadline = std::time::Instant::now() + std::time::Duration::from_secs(30);
    for _ in 0..1000 {
        if std::time::Instant::now() >= deadline {
            return Err(Fault::held(
                "read_bound",
                "Project lookup exceeded30 seconds.",
            ));
        }
        let page = runtime.client.tool("t3_project_list", args.clone())?;
        let projects = page["projects"]
            .as_array()
            .ok_or_else(|| Fault::new("contract_mismatch", "T3 project list omitted projects."))?;
        found.extend(
            projects
                .iter()
                .filter(|p| p[field] == value && p["deletedAt"].is_null())
                .cloned(),
        );
        if page["nextCursor"].is_null() {
            return Ok(found);
        }
        let next = page["nextCursor"]
            .as_u64()
            .filter(|c| {
                args["cursor"].as_u64().is_none_or(|previous| *c > previous) && cursors.insert(*c)
            })
            .ok_or_else(|| {
                Fault::new(
                    "contract_mismatch",
                    "T3 project pagination did not advance.",
                )
            })?;
        args["cursor"] = json!(next);
    }
    Err(Fault::held(
        "read_bound",
        "T3 project list exceeds1000 pages.",
    ))
}

pub fn thread_detail(runtime: &Runtime, thread: &str) -> Result<Value> {
    // Empty metadata page at the public JS-safe position ceiling. Asking for
    // a1-character item would split an emoji surrogate in pinned T3's slice.

    let read = runtime.client.tool(
        "t3_thread_read",
        json!({"threadId":thread,"view":"activity","limit":1,"maxCharsPerItem":8000,"afterPosition":9_007_199_254_740_991_u64}),
    )?;
    if read["thread"]["threadId"] != thread {
        return Err(Fault::new(
            "contract_mismatch",
            "T3 read returned another thread.",
        ));
    }
    Ok(read["thread"].clone())
}

/// T3 root-thread cwd is resolved from the CURRENT project at every turn.
/// Recheck immediately before submission; the local map never moves with it.
pub fn verify_workspace(
    runtime: &Runtime,
    chat: &Chat,
    launch_project: Option<&str>,
) -> Result<()> {
    let detail = if chat.thread_id.is_empty() {
        Value::Null
    } else {
        thread_detail(runtime, &chat.thread_id)?
    };
    if !detail.is_null() {
        if detail["providerInstanceId"] != chat.model["instanceId"]
            || detail["model"] != chat.model["model"]
        {
            return Err(Fault::held("provider_changed","The bound T3 provider/model changed. Restore its recorded Codex selection or start a fresh chat; no new prompt was sent to another provider."));
        }
        allowed_mode(string(&detail, "runtimeMode")?)?;
    }
    let project_id = if let Some(project) = launch_project {
        project
    } else {
        string(&detail, "projectId")?
    };
    let projects = find_projects(runtime, "id", project_id)?;
    if projects.len() != 1 {
        return Err(Fault::held("workspace_changed","The bound T3 project is missing or ambiguous. Restore it or start a fresh chat; no prompt was sent."));
    }
    let current = string(&projects[0], "workspaceRoot")?;
    if !std::path::Path::new(current).is_absolute() || !std::path::Path::new(current).is_dir() {
        return Err(Fault::held("workspace_changed","T3's bound project root must remain an existing absolute folder. Restore it before retrying."));
    }
    let canonical = std::path::Path::new(current).canonicalize().map_err(|_| {
        Fault::held(
            "workspace_changed",
            "The bound T3 folder is unavailable. Restore it before retrying.",
        )
    })?;
    let worktree = detail["worktreePath"]
        .as_str()
        .map(std::path::Path::new)
        .map(std::path::Path::canonicalize)
        .transpose()
        .map_err(|_| {
            Fault::held(
                "workspace_changed",
                "The thread's T3 worktree is unavailable.",
            )
        })?;
    if canonical != std::path::Path::new(&chat.workspace)
        || worktree.is_some_and(|path| path != std::path::Path::new(&chat.workspace))
    {
        return Err(Fault::held("workspace_changed","T3's project root/worktree changed from this chat's saved folder. Restore the original folder in T3 or start a fresh chat; this binding never moves and no new prompt was sent."));
    }
    Ok(())
}

pub fn allowed_mode(mode: &str) -> Result<()> {
    if mode != "approval-required" {
        return Err(Fault::held("runtime_mode_incompatible", format!("The bound T3 thread mode is {mode}; crawl explicitly requires approval-required. Restore that mode in T3 or start a fresh chat. No prompt was sent and no sandbox was broadened.")));
    }
    Ok(())
}

pub fn wait(runtime: &Runtime, thread: &str, run: &str, millis: u64) -> Result<String> {
    let reply = runtime.client.tool(
        "t3_thread_wait",
        json!({"threadId":thread,"runId":run,"timeoutMs":millis}),
    )?;
    if reply["threadId"] != thread || reply["runId"] != run {
        return Err(Fault::new(
            "contract_mismatch",
            "T3 wait did not return the bound thread/run.",
        ));
    }
    let status = string(&reply, "status")?;
    if !terminal(status)
        && !matches!(
            status,
            "preparing" | "queued" | "starting" | "running" | "waiting"
        )
    {
        return Err(Fault::new(
            "contract_mismatch",
            "T3 wait returned an unknown run status.",
        ));
    }
    Ok(status.to_owned())
}

pub fn terminal(status: &str) -> bool {
    matches!(
        status,
        "completed" | "failed" | "cancelled" | "interrupted" | "rolled_back"
    )
}

pub fn interrupt(runtime: &Runtime, thread: &str, operation: &Operation) -> Result<String> {
    let run = operation.run_id.as_deref().ok_or_else(||Fault::new("outcome_unknown", "Cancel is recorded, but the send receipt has no run ID yet. No other run will be interrupted."))?;
    let reply = runtime.client.tool(
        "t3_thread_interrupt",
        json!({"threadId":thread,"runId":run,
        "reason":"Minerva Stop", "clientRequestId":format!("cancel-{}",operation.request_id)}),
    )?;
    if reply["threadId"] != thread || reply["runId"] != run {
        return Err(Fault::new(
            "contract_mismatch",
            "T3 interrupt did not confirm the bound thread/run.",
        ));
    }
    wait(runtime, thread, run, 1)
}

pub fn settled_reply(status: &str, snapshot: &Snapshot) -> Value {
    let activity = snapshot.activity();
    if status == "completed" {
        let text = snapshot.answer();
        if !text.is_empty() {
            return json!({"kind":"answer","text":text,"activity":activity,"cause":"turn_completed"});
        }
    }
    let detail = snapshot
        .items
        .iter()
        .filter(|i| i["type"] == "error")
        .filter_map(|i| i["text"].as_str())
        .collect::<Vec<_>>()
        .join("\n");
    json!({"kind":"error","code":status,"text":format!("T3 turn {status}. {detail}"),
        "activity":activity,"cause":"turn_completed"})
}

pub fn verify_chat(chat: &Chat, runtime: &Runtime) -> Result<()> {
    if chat.lost
        || chat.base_dir != runtime.receipt.base_dir
        || chat.epoch != runtime.receipt.base_identity
    {
        return Err(Fault::new("thread_lost", "The chat's T3 state was replaced or its thread was lost. Start a new Minerva chat for a fresh thread; history is retained and never reconstructed into a replacement thread."));
    }
    Ok(())
}
