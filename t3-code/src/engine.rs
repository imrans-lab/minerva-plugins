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

    fn stopped_run(&self, chat: &Chat, run: &str) -> Result<bool> {
        let tokens = self
            .cancellations
            .lock()
            .map_err(|_| Fault::new("lock_failed", "Cancel lock failed."))?;
        Ok(chat
            .operations
            .iter()
            .any(|o| o.run_id.as_deref() == Some(run) && tokens.contains(&o.token)))
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
                "thread_lost":chat.lost,"outcome_unknown":op.is_some_and(|o|o.attempted && !o.accepted && !o.refused),
                "deferred":op.is_some_and(|o|o.deferred),"refused":op.is_some_and(|o|o.refused),
                "delivered_via":op.and_then(|o|o.delivered_via.as_deref()),
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
            // host's notify ledger that the original message was held. A new
            // message that has no submitted receipt is itself held.
            if let Some(id) = args["chat_id"].as_str() {
                if let Some(chat) = self.slot(id)?.chat()? {
                    fault.held = !chat.operations.iter().any(|o| {
                        o.token == args["operation_token"].as_str().unwrap_or("")
                            && o.attempted
                            && !o.refused
                    });
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
            if saved.as_ref().is_some_and(|c|c.operations.iter().any(|o|o.token == token && o.attempted && !o.refused)) {
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
        if let Some(question) = &chat.question {
            if !questions::still_pending(&runtime.client, &chat.thread_id, &question.request_id)? {
                let run = question.run_id.clone();
                chat.question = None;
                for operation in chat
                    .operations
                    .iter_mut()
                    .filter(|o| o.run_id.as_deref() == Some(&run))
                {
                    if operation
                        .reply
                        .as_ref()
                        .is_some_and(|reply| reply["kind"] == "question")
                    {
                        operation.reply = None;
                        operation.settled = false;
                    }
                }
                slot.publish(&self.store, &chat)?;
            }
        }
        let index = if let Some(index) = chat.operations.iter().position(|o| o.token == token) {
            if args["resume"] != true && chat.operations[index].input != text {
                return Err(Fault::held(
                    "operation_conflict",
                    "This operation token already names different input. No new prompt was sent.",
                ));
            }
            if let Some(reply) = chat.operations[index]
                .reply
                .as_ref()
                .filter(|reply| chat.operations[index].settled || reply["kind"] == "question")
            {
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
            self.new_input_gate(&slot, &mut chat, &runtime)?;
            let op = self.prepare(&slot, &mut chat, &runtime, token, text)?;
            chat.operations.push(op);
            // The full client request is durable BEFORE any launch/send/respond.
            slot.publish(&self.store, &chat)?;
            if let Some(reply) = chat.operations.last().and_then(|o| o.reply.as_ref()) {
                let mut reply = reply.clone();
                reply["operation_token"] = json!(token);
                if self.honor_stop(&slot, &chat, chat.operations.len() - 1, &runtime)? {
                    return Err(Fault::held(
                        "cancelled",
                        "Stop is recorded for the bound run. No question answer was submitted.",
                    ));
                }
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
        if let Err(fault) = self.submit(&slot, &mut chat, index, &runtime) {
            let operation = &mut chat.operations[index];
            if operation.tool == "t3_pending_request" && !operation.attempted && !operation.refused
            {
                if let Some(question) = operation.question_backup.clone() {
                    chat.question = Some(question);
                    operation.refused = true;
                    operation.settled = true;
                    let mut reply = fault.reply();
                    reply["operation_token"] = json!(operation.token);
                    operation.reply = Some(reply);
                    slot.publish(&self.store, &chat)?;
                }
            }
            return Err(fault);
        }
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
        self.honor_stop(&slot, &chat, index, &runtime)?;
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
            chat.operations[index].deferred = true;
            json!({"kind":"error","code":"permission_deferred","deferred":true,"held":false,"hold_reason":"permission_deferred","text":"T3 Code needs permission. Approval handling is deferred in crawl; answer in T3 or stop this run. Resume the original operation to observe this exact run; new text is held until it is settled. The sandbox was not broadened.","activity":activity,"cause":"input_requested"})
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
        if chat.operations[index].settled {
            for operation in chat
                .operations
                .iter_mut()
                .filter(|o| o.run_id.as_deref() == Some(&run))
            {
                operation.terminal_state = Some(status.clone());
                operation.settled = true;
                operation.deferred = false;
                if operation.accepted {
                    let mut final_reply = reply.clone();
                    final_reply["operation_token"] = json!(operation.token);
                    operation.reply = Some(final_reply);
                } else if !operation.refused {
                    operation.reply = Some(Fault::new("outcome_unknown","The bound backend run finished, but this question answer's acceptance was never confirmed. It is not replayed.").reply());
                }
            }
        } else if reply["kind"] == "question" {
            chat.operations[index].reply = Some(reply.clone());
        }
        slot.publish(&self.store, &chat)?;
        if let Some(cause) = reply["cause"].as_str() {
            wake(peer, cause, id, &chat.thread_id, token)?;
        }
        Ok(reply)
    }

    fn new_input_gate(&self, slot: &Slot, chat: &mut Chat, runtime: &Runtime) -> Result<()> {
        if let Some(question) = &chat.question {
            if slot.stopped_run(chat, &question.run_id)? {
                if let Some(index) = chat
                    .operations
                    .iter()
                    .rposition(|o| o.run_id.as_deref() == Some(&question.run_id))
                {
                    self.honor_stop(slot, chat, index, runtime)?;
                    return Err(held_prior(&chat.operations[index]));
                }
            }
            return Ok(());
        }
        let Some(index) = chat
            .operations
            .iter()
            .rposition(|operation| !operation.settled)
        else {
            return Ok(());
        };
        if let Some(run) = chat.operations[index].run_id.clone() {
            self.honor_stop(slot, chat, index, runtime)?;
            let status = turn::wait(runtime, &chat.thread_id, &run, 1)?;
            if status == "completed" {
                let snapshot = Snapshot::read(&runtime.client, &chat.thread_id, &run)?;
                let final_reply = turn::settled_reply(&status, &snapshot);
                let mut notice = Fault::held("prior_run_completed",format!("Earlier turn finished in T3 while this chat was waiting; its answer:\n\n{}\n\nNew text was not submitted. Your next message can proceed.",snapshot.answer_notice()));
                notice.prior_operation =
                    Some((chat.operations[index].token.clone(), Some(run.clone())));
                for operation in chat
                    .operations
                    .iter_mut()
                    .filter(|o| o.run_id.as_deref() == Some(&run))
                {
                    operation.settled = true;
                    operation.deferred = false;
                    operation.terminal_state = Some(status.clone());
                    if operation.accepted {
                        let mut reply = final_reply.clone();
                        reply["operation_token"] = json!(operation.token);
                        operation.reply = Some(reply);
                        operation.delivered_via = Some("held_notice".into());
                    } else if !operation.refused {
                        operation.reply = Some(Fault::new("outcome_unknown","The bound run completed, but this answer's acceptance was never confirmed. It is not replayed.").reply());
                    }
                }
                slot.publish(&self.store, chat)?;
                return Err(notice);
            }
            if matches!(
                status.as_str(),
                "cancelled" | "interrupted" | "failed" | "rolled_back"
            ) {
                for operation in chat
                    .operations
                    .iter_mut()
                    .filter(|o| o.run_id.as_deref() == Some(&run))
                {
                    operation.settled = true;
                    operation.deferred = false;
                    operation.terminal_state = Some(status.clone());
                    if operation.accepted {
                        let mut reply =
                            Fault::new("run_retired", format!("T3 run {run} ended {status}."))
                                .reply();
                        reply["operation_token"] = json!(operation.token);
                        operation.reply = Some(reply);
                    } else if !operation.refused {
                        operation.reply = Some(Fault::new("outcome_unknown","The bound run ended, but this answer's acceptance was never confirmed. It is not replayed.").reply());
                    }
                }
                return slot.publish(&self.store, chat);
            }
        }
        let previous = &chat.operations[index];
        if previous.attempted && !previous.accepted && !previous.refused {
            if previous.retries == 0
                && previous.namespace == runtime.receipt.session_id
                && previous.connection == runtime.client.connection
            {
                // A retry recovers only the ORIGINAL receipt. The new text
                // still receives a held refusal, never its pending/answer.
                let recovery = self.submit(slot, chat, index, runtime);
                let mut refusal = held_prior(&chat.operations[index]);
                if let Err(error) = recovery {
                    refusal.text.push_str(&format!(" Recovery: {}", error.text));
                }
                return Err(refusal);
            }
            if !chat.thread_id.is_empty() {
                turn::thread_detail(runtime, &chat.thread_id)?;
            }
        }
        Err(held_prior(&chat.operations[index]))
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
            refused: false,
            retries: 0,
            deferred: false,
            question_backup: None,
            terminal_state: None,
            delivered_via: None,
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
            let backup = question.clone();
            if questions::answer(&mut question, text)? {
                operation.question_backup = Some(backup);
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
                return Err(held_prior(previous));
            }
        }
        if chat.thread_id.is_empty() {
            turn::allowed_mode(&chat.mode)?;
            let (project, model) = turn::select_project(runtime, &chat.workspace)?;
            chat.model = model.clone();
            operation.tool = "t3_thread_launch".into();
            operation.arguments = json!({"projectId":project,"title":"Minerva chat","modelSelection":model,"runtimeMode":"approval-required","message":text,"clientRequestId":request_id});
        } else {
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
            // Respond has no clientRequestId. Reconcile, never replay.
            let pending = runtime.client.tool(
                "t3_pending_request",
                json!({"action":"list","threadId":chat.thread_id}),
            )?;
            if pending["requestIds"]
                .as_array()
                .is_none_or(|ids| ids.contains(&op.arguments["requestId"]))
            {
                return Err(Fault::new("outcome_unknown","A question answer has no confirmed receipt and still appears pending. Reconcile in T3; it is never automatically resent."));
            }
            chat.operations[index].accepted = true;
            return slot.publish(&self.store, chat);
        }
        let retry = op.attempted;
        if retry
            && (op.namespace != runtime.receipt.session_id
                || op.connection != runtime.client.connection)
        {
            if !chat.thread_id.is_empty() {
                turn::thread_detail(runtime, &chat.thread_id)?;
            }
            return Err(Fault::new("outcome_unknown","The prior send outcome is unknown under another MCP/auth session. The public thread was reread when available, but cannot prove the missing receipt. No blind resend: reconcile in T3 or start a fresh chat."));
        }
        if retry && op.retries >= 1 {
            return Err(Fault::new("outcome_unknown","The one safe same-session retry is exhausted. Reconcile in T3; no new message was submitted."));
        }
        let launch_project = if op.tool == "t3_thread_launch" {
            Some(string(&op.arguments, "projectId")?.to_owned())
        } else {
            None
        };
        let request_id = op.request_id.clone();
        self.check_stop_before_send(slot, chat, index, runtime, retry)?;
        turn::verify_workspace(runtime, chat, launch_project.as_deref())?;
        self.check_stop_before_send(slot, chat, index, runtime, retry)?;
        if retry {
            for operation in chat
                .operations
                .iter_mut()
                .filter(|o| o.request_id == request_id)
            {
                operation.retries = 1;
            }
        }
        if !retry {
            chat.operations[index].namespace = runtime.receipt.session_id.clone();
            chat.operations[index].connection = runtime.client.connection.clone();
        }
        chat.operations[index].attempted = true;
        slot.publish(&self.store, chat)?;
        self.check_stop_before_send(slot, chat, index, runtime, retry)?;
        let op = &chat.operations[index];
        let result = match runtime.client.tool(&op.tool, op.arguments.clone()) {
            Ok(result) => result,
            Err(mut fault) => {
                if !retry && fault.definite_refusal {
                    let op = &mut chat.operations[index];
                    op.refused = true;
                    op.settled = true;
                    if op.tool == "t3_pending_request" {
                        chat.question = op.question_backup.clone();
                    }
                    let mut reply = fault.reply();
                    reply["operation_token"] = json!(op.token);
                    op.reply = Some(reply);
                    slot.publish(&self.store, chat)?;
                } else {
                    fault.held = false;
                    if retry {
                        fault.text.push_str(" A refusal of this retry does not establish that the original request was rejected.");
                    }
                }
                return Err(fault);
            }
        };
        let run = if op.tool == "t3_pending_request" {
            if result["sequence"].as_u64().is_none() {
                return Err(Fault::new("outcome_unknown","T3 question response omitted its dispatch receipt. Reconcile the known run without resending the answer."));
            }
            op.run_id.clone().ok_or_else(|| {
                Fault::new("invalid_state", "Question response lost its bound run.")
            })?
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
            string(&result, "runId")?.to_owned()
        };
        for operation in chat
            .operations
            .iter_mut()
            .filter(|o| o.request_id == request_id)
        {
            operation.run_id = Some(run.clone());
            operation.accepted = true;
            operation.question_backup = None;
        }
        // Publish before waiting. Stop cleanup still runs if publication
        // fails: the local, returned run ID is authoritative for interrupt.
        let published = slot.publish(&self.store, chat);
        let cleanup = self.honor_stop(slot, chat, index, runtime).map(|_| ());
        match (published, cleanup) {
            (Err(mut storage), Err(cancel)) => {
                storage
                    .text
                    .push_str(&format!(" Stop cleanup also failed: {}", cancel.text));
                Err(storage)
            }
            (Err(error), _) | (_, Err(error)) => Err(error),
            (Ok(()), Ok(())) => Ok(()),
        }
    }

    fn honor_stop(
        &self,
        slot: &Slot,
        chat: &Chat,
        index: usize,
        runtime: &Runtime,
    ) -> Result<bool> {
        let operation = &chat.operations[index];
        let Some(run) = operation.run_id.as_deref() else {
            return Ok(false);
        };
        if !slot.stopped_run(chat, run)? {
            return Ok(false);
        }
        turn::interrupt(runtime, &chat.thread_id, operation)?;
        Ok(true)
    }

    fn check_stop_before_send(
        &self,
        slot: &Slot,
        chat: &mut Chat,
        index: usize,
        runtime: &Runtime,
        retry: bool,
    ) -> Result<()> {
        let operation = &chat.operations[index];
        let run_stopped = if let Some(run) = operation.run_id.as_deref() {
            slot.stopped_run(chat, run)?
        } else {
            false
        };
        let stopped = slot.cancelled(&operation.token)? || run_stopped;
        if !stopped {
            return Ok(());
        }
        self.honor_stop(slot, chat, index, runtime)?;
        let fault = Fault::held("cancelled","Stop was recorded. No further request was sent; any earlier uncertain receipt remains unresolved.");
        if !retry {
            let operation = &mut chat.operations[index];
            operation.refused = true;
            operation.settled = true;
            if operation.tool == "t3_pending_request" {
                chat.question = operation.question_backup.clone();
            }
            let mut reply = fault.reply();
            reply["operation_token"] = json!(operation.token);
            operation.reply = Some(reply);
            slot.publish(&self.store, chat)?;
        }
        Err(fault)
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

fn held_prior(operation: &Operation) -> Fault {
    let mut fault = Fault::held("prior_operation",format!("New text was not submitted. Prior operation {} (run {}) is unfinished or unconfirmed. Finish or stop it in T3, then retry your message. An unconfirmed receipt needs reconciliation in T3 or a fresh chat.",operation.token,operation.run_id.as_deref().unwrap_or("unconfirmed")));
    fault.prior_operation = Some((operation.token.clone(), operation.run_id.clone()));
    fault
}
