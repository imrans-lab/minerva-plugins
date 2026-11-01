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
    let mut args = json!({"limit":100});
    let mut cursors = BTreeSet::new();
    let mut found = Vec::new();
    for _ in 0..1000 {
        let page = runtime.client.tool("t3_project_list", args.clone())?;
        let projects = page["projects"]
            .as_array()
            .ok_or_else(|| Fault::new("contract_mismatch", "T3 project list omitted projects."))?;
        found.extend(
            projects
                .iter()
                .filter(|p| p["workspaceRoot"] == workspace && p["deletedAt"].is_null())
                .cloned(),
        );
        if page["nextCursor"].is_null() {
            if found.len() > 1 {
                return Err(Fault::held("project_ambiguous", "Multiple T3 projects share this folder. Resolve them in T3 before starting a chat."));
            }
            let project = if let Some(project) = found.pop() {
                project
            } else {
                runtime.client.tool(
                    "t3_project_create",
                    json!({"title":"Minerva", "workspaceRoot":workspace,
                    "createWorkspaceRootIfMissing":false,"defaultModelSelection":fallback}),
                )?
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
                    return Err(Fault::held("codex_unavailable", "This T3 project's default selection is not an available Codex model. Choose its default in T3; the plugin will not replace it."));
                }
                selected.clone()
            };
            return Ok((string(&project, "id")?.to_owned(), selection));
        }
        let next = page["nextCursor"]
            .as_u64()
            .filter(|c| cursors.insert(*c))
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
        || chat.epoch != runtime.receipt.server_epoch
    {
        return Err(Fault::new("thread_lost", "The chat's T3 state was replaced or its thread was lost. Start a new Minerva chat for a fresh thread; history is retained and never reconstructed into a replacement thread."));
    }
    Ok(())
}
