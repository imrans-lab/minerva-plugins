//! afterPosition pages a snapshot. Always start again at position zero for a
//! settled result; never assume an earlier streaming item is immutable.

use crate::{
    fault::{string, Fault, Result},
    mcp::Client,
};
use serde_json::{json, Value};
use std::collections::BTreeSet;
use std::time::{Duration, Instant};

pub struct Snapshot {
    pub thread: Value,
    pub items: Vec<Value>,
}

impl Snapshot {
    pub fn read(client: &Client, thread: &str, run: &str) -> Result<Self> {
        let mut arguments =
            json!({"threadId":thread,"view":"activity","limit":100,"maxCharsPerItem":50000});
        let mut items = Vec::new();
        let mut positions = BTreeSet::new();
        let mut detail = Value::Null;
        let mut total = 0usize;
        let deadline = Instant::now() + Duration::from_secs(30);
        for _ in 0..1000 {
            read_budget(deadline)?;
            let page = client.tool("t3_thread_read", arguments.clone())?;
            if string(&page["thread"], "threadId")? != thread {
                return Err(Fault::new(
                    "contract_mismatch",
                    "T3 read returned another thread.",
                ));
            }
            if detail.is_null() {
                detail = page["thread"].clone();
            }
            let rows = page["items"]
                .as_array()
                .ok_or_else(|| Fault::new("contract_mismatch", "T3 read has no item array."))?;
            for row in rows {
                if row["runId"] != run || row["sourceThreadId"] != thread {
                    continue;
                }
                let mut item = row.clone();
                let item_id = string(row, "itemId")?;
                let mut text = row["text"].as_str().unwrap_or("").to_owned();
                let mut truncated = row["textTruncated"].as_bool().ok_or_else(|| {
                    Fault::new("contract_mismatch", "T3 item has no truncation flag.")
                })?;
                let mut offset = row["nextTextOffset"].as_u64();
                let mut seen_offsets = BTreeSet::new();
                let mut previous_offset = 0;
                while truncated {
                    read_budget(deadline)?;
                    let next = offset
                        .filter(|o| *o > previous_offset && seen_offsets.insert(*o))
                        .ok_or_else(|| {
                            Fault::new(
                                "contract_mismatch",
                                "T3 item text pagination did not advance.",
                            )
                        })?;
                    previous_offset = next;
                    if seen_offsets.len() > 1000 || text.len() > 16 * 1024 * 1024 {
                        return Err(Fault::new("read_bound", "T3 item exceeds the bounded read. No incomplete answer is presented as final."));
                    }
                    let more = client.tool("t3_thread_read", json!({"threadId":thread,"view":"activity","itemId":item_id,"textOffset":next,"maxCharsPerItem":50000}))?;
                    let part = more["items"]
                        .as_array()
                        .and_then(|rows| {
                            rows.iter().find(|v| {
                                v["itemId"] == item_id
                                    && v["runId"] == run
                                    && v["sourceThreadId"] == thread
                            })
                        })
                        .ok_or_else(|| {
                            Fault::new(
                                "contract_mismatch",
                                "T3 text continuation omitted the bound item.",
                            )
                        })?;
                    text.push_str(part["text"].as_str().unwrap_or(""));
                    truncated = part["textTruncated"].as_bool().ok_or_else(|| {
                        Fault::new(
                            "contract_mismatch",
                            "T3 text continuation has no truncation flag.",
                        )
                    })?;
                    offset = part["nextTextOffset"].as_u64();
                }
                total = total.saturating_add(text.len());
                if total > 32 * 1024 * 1024 || items.len() >= 100_000 {
                    return Err(Fault::new("read_bound", "T3 transcript exceeds the bounded read. No incomplete answer is presented as final."));
                }
                item["text"] = json!(text);
                items.push(item);
            }
            match page["hasMore"].as_bool() {
                Some(false) => {
                    return Ok(Self {
                        thread: detail,
                        items,
                    })
                }
                Some(true) => {
                    let next = page["nextPosition"]
                        .as_u64()
                        .filter(|p| {
                            arguments["afterPosition"]
                                .as_u64()
                                .is_none_or(|previous| *p > previous)
                                && positions.insert(*p)
                        })
                        .ok_or_else(|| {
                            Fault::new(
                                "contract_mismatch",
                                "T3 snapshot pagination did not advance.",
                            )
                        })?;
                    arguments["afterPosition"] = json!(next);
                }
                None => return Err(Fault::new("contract_mismatch", "T3 read omitted hasMore.")),
            }
        }
        Err(Fault::new(
            "read_bound",
            "T3 snapshot exceeded1000 pages. No incomplete answer is presented as final.",
        ))
    }

    pub fn answer(&self) -> String {
        self.items
            .iter()
            .filter(|v| v["type"] == "assistant_message")
            .filter_map(|v| v["text"].as_str())
            .collect::<Vec<_>>()
            .join("\n\n")
    }

    pub fn activity(&self) -> Vec<Value> {
        self.items.iter().filter_map(|item| {
            let kind = item["type"].as_str()?;
            if matches!(kind, "assistant_message" | "user_message" | "reasoning") { return None; }
            let text = item["text"].as_str().unwrap_or("");
            let mut value = json!({"kind":kind,"label":item["title"].as_str().filter(|s|!s.is_empty()).unwrap_or(kind),
                "status":item["status"].as_str().unwrap_or("unknown"),"detail":text});
            if kind == "file_change" { value["path"] = json!(text.lines().next().unwrap_or("")); }
            Some(value)
        }).collect()
    }

    pub fn permission_pending(&self) -> bool {
        self.items.iter().any(|v| {
            v["type"] == "approval_request"
                && matches!(
                    v["status"].as_str(),
                    Some("pending" | "waiting" | "in_progress")
                )
        })
    }
}

fn read_budget(deadline: Instant) -> Result<()> {
    if Instant::now() >= deadline {
        return Err(Fault::new("read_bound","The snapshot exceeded its30-second read budget. The accepted run receipt is retained; no incomplete transcript is final."));
    }
    Ok(())
}
