//! Host cards return their opaque keystroke as the next user message. The
//! token maps to a stored request, never directly to an approval decision.

use crate::{
    fault::{string, Fault, Result},
    mcp::Client,
    snapshot::Snapshot,
    storage::{random_id, Question},
};
use serde_json::{json, Value};
use std::collections::BTreeMap;

fn pending(client: &Client, thread: &str) -> Result<Vec<String>> {
    let list = client.tool(
        "t3_pending_request",
        json!({"action":"list","threadId":thread}),
    )?;
    list["requestIds"]
        .as_array()
        .ok_or_else(|| Fault::new("contract_mismatch", "T3 pending request list has no IDs."))?
        .iter()
        .map(|id| {
            id.as_str()
                .filter(|s| !s.is_empty())
                .map(str::to_owned)
                .ok_or_else(|| Fault::new("contract_mismatch", "Invalid pending request ID."))
        })
        .collect()
}

fn corroborate(snapshot: &Snapshot, run: &str, questions: &[Value]) -> Result<()> {
    if snapshot.thread["activeRunId"] != run {
        return Err(Fault::held(
            "question_ambiguous",
            "The pending question does not belong to the bound active run. No answer was sent.",
        ));
    }
    let matches = snapshot
        .items
        .iter()
        .filter(|item| {
            item["type"] == "user_input_request"
                && matches!(
                    item["status"].as_str(),
                    Some("pending" | "waiting" | "running")
                )
        })
        .filter(|item| {
            item["text"]
                .as_str()
                .and_then(|text| serde_json::from_str::<Value>(text).ok())
                == Some(json!(questions))
        })
        .count();
    if matches != 1 {
        return Err(Fault::held("question_ambiguous", "Public T3 question data cannot be uniquely bound to this run. Answer in T3, then resume; no guessed request is used."));
    }
    Ok(())
}

pub fn discover(
    client: &Client,
    snapshot: &Snapshot,
    thread: &str,
    run: &str,
) -> Result<Option<Question>> {
    let ids = pending(client, thread)?;
    if ids.is_empty() {
        return Ok(None);
    }
    if ids.len() != 1 {
        return Err(Fault::held("question_ambiguous", "Multiple T3 user-input requests are pending. Answer them in T3; this crawl refuses to guess their run binding."));
    }
    let request_id = &ids[0];
    let read = client.tool(
        "t3_pending_request",
        json!({"action":"read","threadId":thread,"requestId":request_id}),
    )?;
    if read["requestId"] != request_id.as_str() {
        return Err(Fault::new(
            "contract_mismatch",
            "T3 read another pending request.",
        ));
    }
    let questions = read["questions"]
        .as_array()
        .filter(|v| !v.is_empty())
        .ok_or_else(|| Fault::new("contract_mismatch", "T3 request has no questions."))?
        .clone();
    corroborate(snapshot, run, &questions)?;
    let mut question = Question {
        thread_id: thread.into(),
        run_id: run.into(),
        request_id: request_id.clone(),
        questions,
        index: 0,
        answers: BTreeMap::new(),
        options: BTreeMap::new(),
    };
    new_options(&mut question)?;
    Ok(Some(question))
}

pub fn validate(
    client: &Client,
    snapshot: &Snapshot,
    question: &Question,
    thread: &str,
    run: &str,
) -> Result<()> {
    if question.thread_id != thread
        || question.run_id != run
        || pending(client, thread)? != [question.request_id.clone()]
    {
        return Err(Fault::held(
            "question_expired",
            "This question expired or belongs to another thread/run. No answer was sent.",
        ));
    }
    let read = client.tool(
        "t3_pending_request",
        json!({"action":"read","threadId":thread,"requestId":question.request_id}),
    )?;
    if read["requestId"] != question.request_id || read["questions"] != json!(question.questions) {
        return Err(Fault::held(
            "question_expired",
            "T3 changed this request. Refresh the current question; no stale option was sent.",
        ));
    }
    corroborate(snapshot, run, &question.questions)
}

fn new_options(question: &mut Question) -> Result<()> {
    question.options.clear();
    let current = question
        .questions
        .get(question.index)
        .ok_or_else(|| Fault::new("invalid_state", "Question index is invalid."))?;
    let options = current["options"]
        .as_array()
        .ok_or_else(|| Fault::new("contract_mismatch", "T3 question has no options array."))?;
    for option in options {
        let answer = option["value"]
            .as_str()
            .unwrap_or(string(option, "label")?)
            .to_owned();
        question
            .options
            .insert(format!("t3-option:{}", random_id()?), answer);
    }
    Ok(())
}

pub fn card(question: &Question, activity: Vec<Value>) -> Result<Value> {
    let current = question
        .questions
        .get(question.index)
        .ok_or_else(|| Fault::new("invalid_state", "Question index is invalid."))?;
    let options = current["options"]
        .as_array()
        .ok_or_else(|| Fault::new("contract_mismatch", "T3 question has no options array."))?;
    let mut output = Vec::new();
    for option in options {
        let label = string(option, "label")?;
        let answer = option["value"].as_str().unwrap_or(label);
        let key = question
            .options
            .iter()
            .find_map(|(key, value)| (value == answer).then_some(key))
            .ok_or_else(|| Fault::new("invalid_state", "Stored question option is unavailable."))?;
        let description = option["description"].as_str().unwrap_or("");
        output.push(json!({"label":if description.is_empty() { label.to_owned() } else { format!("{label} — {description}") },"keystroke":key}));
    }
    Ok(
        json!({"kind":"question","text":string(current,"question")?,"options":output,"activity":activity}),
    )
}

/// Store partial answers locally; a multi-question request is answered once,
/// only after each question has a value. Native Codex defaults allow free text.
pub fn answer(question: &mut Question, text: &str) -> Result<bool> {
    let current = question
        .questions
        .get(question.index)
        .ok_or_else(|| Fault::new("invalid_state", "Question index is invalid."))?;
    let answer = if let Some(value) = question.options.get(text) {
        value.clone()
    } else {
        if text.starts_with("t3-option:")
            || current["allowCustomAnswer"] == false
            || text.trim().is_empty()
        {
            return Err(Fault::held("question_expired", "That option is expired, belongs to another request, or is not an allowed answer. No backend answer was sent."));
        }
        text.to_owned()
    };
    question.answers.insert(
        string(current, "id")?.to_owned(),
        if current["multiSelect"] == true {
            json!([answer])
        } else {
            json!(answer)
        },
    );
    question.index += 1;
    if question.index == question.questions.len() {
        return Ok(true);
    }
    new_options(question)?;
    Ok(false)
}
