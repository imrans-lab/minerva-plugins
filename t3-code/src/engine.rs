use crate::{
    contract::Contract,
    fault::{string, Fault, Result},
    probe::Settings,
    protocol::Peer,
    questions,
    runtime::{Runtime, RuntimeCache},
    snapshot::Snapshot,
    storage::{random_id, Chat, Operation, Store},
    turn,
};
use serde_json::{json, Value};
use std::collections::{BTreeMap, BTreeSet};
use std::sync::{Arc, Mutex};

struct Slot {
    generate: Mutex<()>,
    chat: Mutex<Option<Chat>>,
    cancellations: Mutex<BTreeSet<String>>,
}

impl Slot {
    fn chat(&self) -> Result<Option<Chat>> {
        self.chat
            .lock()
            .map(|c| c.clone())
            .map_err(|_| Fault::new("lock_failed", "Chat lock failed."))
    }

    fn publish(&self, store: &Store, chat: &Chat) -> Result<()> {
        store.save(chat)?;
        *self
            .chat
            .lock()
            .map_err(|_| Fault::new("lock_failed", "Chat lock failed."))? = Some(chat.clone());
        Ok(())
    }

    fn cancelled(&self, token: &str) -> Result<bool> {
        self.cancellations
            .lock()
            .map(|c| c.contains(token))
            .map_err(|_| Fault::new("lock_failed", "Cancel lock failed."))
    }
}

pub struct Engine {
    store: Store,
    slots: Mutex<BTreeMap<String, Arc<Slot>>>,
    pub runtimes: RuntimeCache,
}

impl Engine {
    pub fn open(settings: &Settings) -> Result<Self> {
        Ok(Self {
            store: Store::open(&settings.private)?,
            slots: Mutex::new(BTreeMap::new()),
            runtimes: RuntimeCache::default(),
        })
    }

    fn slot(&self, id: &str) -> Result<Arc<Slot>> {
        let mut slots = self
            .slots
            .lock()
            .map_err(|_| Fault::new("lock_failed", "Chat registry lock failed."))?;
        if let Some(slot) = slots.get(id) {
            return Ok(Arc::clone(slot));
        }
        let slot = Arc::new(Slot {
            generate: Mutex::new(()),
            chat: Mutex::new(self.store.load(id)?),
            cancellations: Mutex::new(self.store.cancellations(id)?),
        });
        slots.insert(id.into(), Arc::clone(&slot));
        Ok(slot)
    }

    pub fn chat_status(&self, id: &str) -> Result<Value> {
        let chat = self.slot(id)?.chat()?;
        Ok(if let Some(chat) = chat {
            let op = chat.operations.last();
            json!({"thread_id":chat.thread_id,"run_id":op.and_then(|o|o.run_id.as_deref()).unwrap_or(""),
                "workspace":chat.workspace,"permission":crate::runtime::permission(&chat.mode),"model_selection":chat.model,
                "thread_lost":chat.lost,"outcome_unknown":op.is_some_and(|o|o.attempted && !o.accepted),
                "operation_token":op.map(|o|o.token.as_str()).unwrap_or("")})
        } else {
            json!({"thread_id":"","run_id":""})
        })
    }

    pub fn generate(
        &self,
        peer: &Peer,
        settings: &Settings,
        contract: &Contract,
        args: &Value,
    ) -> Result<Value> {
        let mut result = self.generate_inner(peer, settings, contract, args);
        if let Err(fault) = &mut result {
            // An I/O/JSON error after a submitted request must never tell the
            // host's notify ledger that the original message was held.
            if let Some(id) = args["chat_id"].as_str() {
                if let Some(mut chat) = self.slot(id)?.chat()? {
                    if chat.operations.iter().any(|o| {
                        o.token == args["operation_token"].as_str().unwrap_or("") && o.attempted
                    }) {
                        fault.held = false;
                    }
                    if fault.code == "question_expired" {
                        chat.question = None;
                        self.slot(id)?.publish(&self.store, &chat)?;
                    }
                }
            }
            if fault.code == "thread_lost" {
                let id = input(args, "chat_id", 100)?;
                let slot = self.slot(id)?;
                if let Some(mut chat) = slot.chat()? {
                    if !chat.lost {
                        chat.lost = true;
                        slot.publish(&self.store, &chat)?;
                        wake(
                            peer,
                            "thread_lost",
                            id,
                            &chat.thread_id,
                            args["operation_token"].as_str().unwrap_or(""),
                        )?;
                    }
                }
            }
        }
        result
    }

    fn generate_inner(
        &self,
        peer: &Peer,
        settings: &Settings,
        contract: &Contract,
        args: &Value,
    ) -> Result<Value> {
        let id = input(args, "chat_id", 100)?;
        let token = input(args, "operation_token", 256)?;
        let text = args["text"]
            .as_str()
            .ok_or_else(|| Fault::held("invalid_request", "text must be a string."))?;
        if text.chars().count() > 120_000 {
            return Err(Fault::held(
                "invalid_request",
                "Message exceeds T3's120000-character limit.",
            ));
        }
        let slot = self.slot(id)?;
        let _gate = slot.generate.try_lock().map_err(|_|Fault::held("chat_busy","A generate call already owns this chat. Resume its operation instead of sending concurrently."))?;
        let saved = slot.chat()?;
        let runtime = self.runtimes.get(settings,contract).map_err(|mut fault| {
            if saved.as_ref().is_some_and(|c|c.operations.iter().any(|o|o.token == token && o.attempted)) {
                fault.held = false;
                fault.text.push_str(" The original operation may already be accepted; its receipt remains authoritative.");
            }
            fault
        })?;
        if let Some(chat) = &saved {
            turn::verify_chat(chat, &runtime)?;
        }
        let mut chat = if let Some(chat) = saved {
            chat
        } else {
            if args["resume"] == true {
                return Err(Fault::held(
                    "operation_lost",
                    "No receipt exists for this resume. No prompt was sent.",
                ));
            }
            if settings.workspace.as_os_str().is_empty() {
                return Err(Fault::held(
                    "project_unsaved",
                    "Save the Minerva project as a .minproj before starting a T3 chat.",
                ));
            }
            let workspace = settings
                .workspace
                .canonicalize()?
                .to_string_lossy()
                .into_owned();
            Chat {
                schema: 1,
                chat_id: id.into(),
                workspace,
                base_dir: runtime.receipt.base_dir.clone(),
                epoch: runtime.receipt.server_epoch.clone(),
                thread_id: String::new(),
                mode: "approval-required".into(),
                model: Value::Null,
                operations: Vec::new(),
                question: None,
                lost: false,
            }
        };
        let index = if let Some(index) = chat.operations.iter().position(|o| o.token == token) {
            if args["resume"] != true && chat.operations[index].input != text {
                return Err(Fault::held(
                    "operation_conflict",
                    "This operation token already names different input. No new prompt was sent.",
                ));
            }
            if let Some(reply) = &chat.operations[index].reply {
                if reply["kind"] == "question" {
                    if index + 1 != chat.operations.len() {
                        return Err(Fault::held("question_expired","That question operation has been retired. Use the current request card."));
                    }
                    let question = chat.question.as_ref().ok_or_else(|| {
                        Fault::held("question_expired", "This question is no longer pending.")
                    })?;
                    let snapshot =
                        Snapshot::read(&runtime.client, &chat.thread_id, &question.run_id)?;
                    questions::validate(
                        &runtime.client,
                        &snapshot,
                        question,
                        &chat.thread_id,
                        &question.run_id,
                    )?;
                }
                return Ok(reply.clone());
            }
            index
        } else {
            if args["resume"] == true {
                return Err(Fault::held(
                    "operation_lost",
                    "Unknown operation token. Resume never creates or resends a prompt.",
                ));
            }
            if slot.cancelled(token)? {
                return Err(Fault::held(
                    "cancelled",
                    "Stop was recorded before submission. No prompt was sent.",
                ));
            }
            let op = self.prepare(&slot, &mut chat, &runtime, token, text)?;
            chat.operations.push(op);
            // The full client request is durable BEFORE any launch/send/respond.
            slot.publish(&self.store, &chat)?;
            if let Some(reply) = chat.operations.last().and_then(|o| o.reply.as_ref()) {
                let mut reply = reply.clone();
                reply["operation_token"] = json!(token);
                chat.operations
                    .last_mut()
                    .ok_or_else(|| Fault::new("invalid_state", "Operation was not stored."))?
                    .reply = Some(reply.clone());
                slot.publish(&self.store, &chat)?;
                wake(peer, "input_requested", id, &chat.thread_id, token)?;
                return Ok(reply);
            }
            chat.operations.len() - 1
        };
        self.submit(&slot, &mut chat, index, &runtime)?;
        let operation = &chat.operations[index];
        let run = operation
            .run_id
            .as_deref()
            .ok_or_else(|| {
                Fault::new(
                    "outcome_unknown",
                    "Accepted receipt has no run ID. No other run will be read or interrupted.",
                )
            })?
            .to_owned();
        if slot.cancelled(token)? {
            turn::interrupt(&runtime, &chat.thread_id, operation)?;
        }
        let budget = args["wait_budget_ms"]
            .as_u64()
            .filter(|ms| *ms > 0)
            .unwrap_or(1000)
            .clamp(1, 2000);
        let status = turn::wait(&runtime, &chat.thread_id, &run, budget)?;
        let snapshot = Snapshot::read(&runtime.client, &chat.thread_id, &run)?;
        chat.mode = string(&snapshot.thread, "runtimeMode")?.into();
        let mut reply = if turn::terminal(&status) {
            // This is a fresh complete snapshot after the bound run settled.
            chat.operations[index].settled = true;
            chat.question = None;
            turn::settled_reply(&status, &snapshot)
        } else if snapshot.permission_pending() {
            let mut activity = snapshot.activity();
            activity.push(json!({"kind":"permission_request","label":"Permission required in T3 Code","status":"deferred"}));
            json!({"kind":"error","code":"permission_deferred","text":"T3 Code needs permission. Approval handling is deferred in crawl; answer in T3 or stop this run. The sandbox was not broadened.","activity":activity,"cause":"input_requested"})
        } else if status == "waiting" {
            if let Some(question) =
                questions::discover(&runtime.client, &snapshot, &chat.thread_id, &run)?
            {
                let mut reply = questions::card(&question, snapshot.activity())?;
                reply["cause"] = json!("input_requested");
                chat.question = Some(question);
                reply
            } else {
                pending(token, &status)
            }
        } else {
            pending(token, &status)
        };
        reply["operation_token"] = json!(token);
        if reply["kind"] != "pending" {
            chat.operations[index].reply = Some(reply.clone());
        }
        slot.publish(&self.store, &chat)?;
        if let Some(cause) = reply["cause"].as_str() {
            wake(peer, cause, id, &chat.thread_id, token)?;
        }
        Ok(reply)
    }

    fn prepare(
        &self,
        slot: &Slot,
        chat: &mut Chat,
        runtime: &Runtime,
        token: &str,
        text: &str,
    ) -> Result<Operation> {
        let request_id = random_id()?;
        let mut operation = Operation {
            token: token.into(),
            input: text.into(),
            request_id: request_id.clone(),
            namespace: runtime.receipt.session_id.clone(),
            connection: runtime.client.connection.clone(),
            tool: String::new(),
            arguments: Value::Null,
            run_id: None,
            reply: None,
            settled: false,
            attempted: false,
            accepted: false,
        };
        if let Some(mut question) = chat.question.clone() {
            let snapshot = Snapshot::read(&runtime.client, &chat.thread_id, &question.run_id)?;
            questions::validate(
                &runtime.client,
                &snapshot,
                &question,
                &chat.thread_id,
                &question.run_id,
            )?;
            operation.run_id = Some(question.run_id.clone());
            if let Some(previous) = chat.operations.last_mut() {
                previous.settled = true;
            }
            if questions::answer(&mut question, text)? {
                operation.tool = "t3_pending_request".into();
                operation.arguments = json!({"action":"respond","threadId":chat.thread_id,"requestId":question.request_id,"answers":question.answers});
                chat.question = None;
            } else {
                operation.tool = "local-question".into();
                operation.accepted = true;
                operation.reply = Some(questions::card(&question, snapshot.activity())?);
                chat.question = Some(question);
            }
            return Ok(operation);
        }
        if text.starts_with("t3-option:") {
            return Err(Fault::held("question_expired","This opaque option no longer belongs to a pending request in this chat. No prompt was sent."));
        }
        if text.trim().is_empty() {
            return Err(Fault::held(
                "invalid_request",
                "The newest user message is empty.",
            ));
        }
        if let Some(previous) = chat.operations.last_mut() {
            if !previous.settled {
                let run = previous.run_id.as_deref().ok_or_else(||Fault::held("outcome_unknown","A previous send has no confirmed run ID. Read/reconcile that thread in T3 or start a fresh chat; no new prompt is submitted."))?;
                if !turn::terminal(&turn::wait(runtime, &chat.thread_id, run, 1)?) {
                    return Err(Fault::held("chat_busy","The chat's previous backend run is still active. Resume or stop that exact operation before sending another prompt."));
                }
                previous.settled = true;
            }
        }
        if chat.thread_id.is_empty() {
            turn::allowed_mode(&chat.mode)?;
            let (project, model) = turn::select_project(runtime, &chat.workspace)?;
            chat.model = model.clone();
            operation.tool = "t3_thread_launch".into();
            operation.arguments = json!({"projectId":project,"title":"Minerva chat","modelSelection":model,"runtimeMode":"approval-required","message":text,"clientRequestId":request_id});
        } else {
            let snapshot = Snapshot::read(&runtime.client, &chat.thread_id, "")?;
            if snapshot.thread["providerInstanceId"] != chat.model["instanceId"]
                || snapshot.thread["model"] != chat.model["model"]
            {
                return Err(Fault::held("provider_changed","The bound T3 thread's provider/model changed outside this chat. Restore its recorded Codex selection or start a fresh chat; no message was sent to another provider."));
            }
            chat.mode = string(&snapshot.thread, "runtimeMode")?.into();
            turn::allowed_mode(&chat.mode)?;
            operation.tool = "t3_thread_send".into();
            operation.arguments = json!({"threadId":chat.thread_id,"message":text,"mode":"queue","clientRequestId":request_id});
        }
        slot.publish(&self.store, chat)?;
        Ok(operation)
    }

    fn submit(&self, slot: &Slot, chat: &mut Chat, index: usize, runtime: &Runtime) -> Result<()> {
        let op = &chat.operations[index];
        if op.accepted {
            return Ok(());
        }
        if !matches!(
            op.tool.as_str(),
            "t3_thread_launch" | "t3_thread_send" | "t3_pending_request"
        ) {
            return Err(Fault::held(
                "invalid_state",
                "Stored operation names an unsupported mutation. Nothing was submitted.",
            ));
        }
        if op.attempted && op.tool == "t3_pending_request" {
            // Respond has no clientRequestId. Never retry its unknown outcome.
            let pending = runtime.client.tool(
                "t3_pending_request",
                json!({"action":"list","threadId":chat.thread_id}),
            )?;
            if pending["requestIds"]
                .as_array()
                .is_none_or(|ids| ids.contains(&op.arguments["requestId"]))
            {
                return Err(Fault::new("outcome_unknown","A question answer was submitted without a confirmed receipt. Its request still appears pending; reconcile in T3, never automatically resend."));
            }
            chat.operations[index].accepted = true;
            return slot.publish(&self.store, chat);
        }
        if op.attempted
            && (op.namespace != runtime.receipt.session_id
                || op.connection != runtime.client.connection)
        {
            if !chat.thread_id.is_empty() {
                Snapshot::read(&runtime.client, &chat.thread_id, "")?;
            }
            return Err(Fault::new("outcome_unknown","The prior send outcome is unknown under another MCP/auth session. The public thread was reread when available, but cannot prove the missing receipt. No blind resend: reconcile in T3 or start a fresh chat."));
        }
        if slot.cancelled(&op.token)? && !op.attempted {
            return Err(Fault::held(
                "cancelled",
                "Stop was recorded before submission. Nothing was sent.",
            ));
        }
        chat.operations[index].attempted = true;
        slot.publish(&self.store, chat)?;
        let op = &chat.operations[index];
        let result = runtime.client.tool(&op.tool, op.arguments.clone())?;
        if op.tool == "t3_pending_request" {
            if result["sequence"].as_u64().is_none() {
                return Err(Fault::new("outcome_unknown","T3 question response omitted its dispatch receipt. Reconcile the known run without resending the answer."));
            }
        } else {
            let thread = string(&result, "threadId")?.to_owned();
            if !chat.thread_id.is_empty() && chat.thread_id != thread {
                return Err(Fault::new(
                    "outcome_unknown",
                    "T3 send returned another thread. The original receipt remains unresolved.",
                ));
            }
            chat.thread_id = thread;
            slot.publish(&self.store, chat)?;
            let run = string(&result, "runId")?.to_owned();
            chat.operations[index].run_id = Some(run);
        }
        chat.operations[index].accepted = true;
        // Accepted run identity is durable BEFORE the first wait/read.
        slot.publish(&self.store, chat)
    }

    pub fn cancel(&self, settings: &Settings, contract: &Contract, args: &Value) -> Result<Value> {
        let id = input(args, "chat_id", 100)?;
        let token = input(args, "operation_token", 256)?;
        let slot = self.slot(id)?;
        {
            let mut tokens = slot
                .cancellations
                .lock()
                .map_err(|_| Fault::new("lock_failed", "Cancel lock failed."))?;
            tokens.insert(token.into());
            self.store.cancel(id, &tokens)?;
        }
        let Some(chat) = slot.chat()? else {
            return Ok(
                json!({"cancelled":false,"state":"cancel_recorded","operation_token":token}),
            );
        };
        let Some(op) = chat.operations.iter().find(|o| o.token == token) else {
            return Ok(
                json!({"cancelled":false,"state":"cancel_recorded","operation_token":token}),
            );
        };
        let runtime = self.runtimes.get(settings, contract)?;
        turn::verify_chat(&chat, &runtime)?;
        let status = turn::interrupt(&runtime, &chat.thread_id, op)?;
        Ok(
            json!({"cancelled":matches!(status.as_str(),"cancelled"|"interrupted"),"state":status,
            "thread_id":chat.thread_id,"run_id":op.run_id,"operation_token":token}),
        )
    }
}

fn input<'a>(args: &'a Value, key: &str, max: usize) -> Result<&'a str> {
    args[key]
        .as_str()
        .filter(|s| !s.is_empty() && s.len() <= max)
        .ok_or_else(|| {
            Fault::held(
                "invalid_request",
                format!("{key} must contain1–{max} UTF-8 bytes."),
            )
        })
}

fn pending(token: &str, status: &str) -> Value {
    json!({"kind":"pending","operation_token":token,"state":status})
}

fn wake(peer: &Peer, cause: &str, chat: &str, thread: &str, token: &str) -> Result<()> {
    peer.write(&json!({"jsonrpc":"2.0","method":"minerva/plugin_event",
        "params":{"event":"t3_code.turn_completed","payload":{"cause":cause,"chat_id":chat,"thread_id":thread,"operation_token":token}}}))
        .map_err(|e|Fault::new("host_disconnected",e))
}
