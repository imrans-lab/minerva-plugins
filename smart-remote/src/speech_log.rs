//! Request-local projection of Minerva's authoritative speech log.
use crate::host::{HostError, HostLink};
use crate::message::PluginMsg;
use serde::Serialize;
use serde_json::{json, Value};
use std::sync::Arc;
use std::time::{SystemTime, UNIX_EPOCH};

#[derive(Debug, Clone, Serialize, PartialEq, Eq)]
pub struct LogItem {
    pub log_id: String,
    pub age_s: u64,
    pub summary: String,
    pub heard: bool,
}
pub(crate) enum Action {
    Count,
    Page(u64, u8),
    Play(String),
    Delete(String, u64, u8),
    DeleteAll(u64, u8),
    ReplayLast,
}
pub(crate) struct Reply {
    pub messages: Vec<PluginMsg>,
    pub page: Option<(u64, u8)>,
    pub failure: Option<HostError>,
}
fn bad() -> HostError {
    HostError::Refused {
        code: String::new(),
        reason: "Malformed speech log response".into(),
    }
}
pub(crate) fn counts(value: &Value) -> Result<(u64, u64), HostError> {
    let (unheard, total) = (number(&value["unheard"])?, number(&value["total"])?);
    if unheard > total {
        return Err(bad());
    }
    Ok((unheard, total))
}
fn number(value: &Value) -> Result<u64, HostError> {
    value
        .as_f64()
        .filter(|n| n.is_finite() && *n >= 0.0 && *n <= 9_007_199_254_740_991.0 && n.fract() == 0.0)
        .map(|n| n as u64)
        .ok_or_else(bad)
}
pub(crate) fn deserialize_number<'de, D: serde::Deserializer<'de>>(
    deserializer: D,
) -> Result<u64, D::Error> {
    let value = <Value as serde::Deserialize>::deserialize(deserializer)?;
    number(&value).map_err(serde::de::Error::custom)
}
fn id(value: &Value) -> Result<String, HostError> {
    value
        .as_str()
        .filter(|s| !s.is_empty() && s.chars().count() <= 128 && !s.contains('\0'))
        .map(str::to_owned)
        .ok_or_else(bad)
}
async fn call(host: &HostLink, args: Value) -> Result<Value, HostError> {
    let result = host.call_capability("host.speech_log", args).await?;
    if result["success"] != true {
        return Err(bad());
    }
    Ok(result)
}
async fn page(host: &HostLink, offset: u64, limit: u8) -> Result<Reply, HostError> {
    let value = call(host, json!({"op":"list","offset":offset,"limit":limit})).await?;
    let (unheard, total) = counts(&value)?;
    let rows = value["items"]
        .as_array()
        .filter(|r| r.len() <= usize::from(limit))
        .ok_or_else(bad)?;
    let now = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map_err(|_| bad())?
        .as_secs();
    let items = rows
        .iter()
        .map(|row| {
            let summary = row["summary"]
                .as_str()
                .filter(|s| !s.contains('\0'))
                .ok_or_else(bad)?;
            Ok(LogItem {
                log_id: id(&row["log_id"])?,
                age_s: now.saturating_sub(number(&row["created_at"])?),
                summary: summary.chars().take(21).collect(),
                heard: row["heard"].as_bool().ok_or_else(bad)?,
            })
        })
        .collect::<Result<Vec<_>, HostError>>()?;
    let mut messages = vec![
        PluginMsg::Missed { unheard },
        PluginMsg::LogItems {
            offset,
            total,
            unheard,
            items,
        },
    ];
    if serde_json::to_vec(&messages[1]).map_err(|_| bad())?.len() > crate::contract::PLUGIN_TEXT_MAX
    {
        return Err(bad());
    }
    if !value["errors"].as_array().ok_or_else(bad)?.is_empty() {
        messages.push(PluginMsg::error(
            crate::message::ErrorCode::Internal,
            "Some speech log records are unavailable",
        ));
    }
    Ok(Reply {
        messages,
        page: Some((offset, limit)),
        failure: None,
    })
}
pub(crate) async fn request(
    host: Arc<HostLink>,
    device: String,
    action: Action,
) -> Result<Reply, HostError> {
    match action {
        Action::Count => {
            let mut reply = page(&host, 0, 1).await?;
            reply
                .messages
                .retain(|m| !matches!(m, PluginMsg::LogItems { .. }));
            reply.page = None;
            Ok(reply)
        }
        Action::Page(offset, limit) => page(&host, offset, limit).await,
        Action::Delete(log_id, offset, limit) => {
            delete(
                &host,
                json!({"op":"delete","log_id":log_id}),
                offset,
                limit,
                "Deleted",
            )
            .await
        }
        Action::DeleteAll(offset, limit) => {
            delete(
                &host,
                json!({"op":"delete_all","confirmed":true}),
                offset,
                limit,
                "Deleted all",
            )
            .await
        }
        Action::Play(log_id) => play(&host, &device, &log_id).await,
        Action::ReplayLast => {
            let mut reply = page(&host, 0, 1).await?;
            let empty = reply
                .messages
                .iter()
                .any(|m| matches!(m, PluginMsg::LogItems { total: 0, .. }));
            let log_id = reply.messages.iter().find_map(|m| {
                if let PluginMsg::LogItems { items, .. } = m {
                    items.first().map(|i| i.log_id.clone())
                } else {
                    None
                }
            });
            reply
                .messages
                .retain(|m| !matches!(m, PluginMsg::LogItems { .. }));
            reply.page = None;
            if let Some(log_id) = log_id {
                reply
                    .messages
                    .extend(play(&host, &device, &log_id).await?.messages);
            } else {
                reply.messages.push(PluginMsg::Status {
                    text: if empty {
                        "Speech log is empty"
                    } else {
                        "No playable speech log entry"
                    }
                    .into(),
                });
            }
            Ok(reply)
        }
    }
}
async fn play(host: &HostLink, device: &str, log_id: &str) -> Result<Reply, HostError> {
    let endpoint = format!("plugin:{}:{device}", crate::data_dir::PLUGIN_ID);
    let value = call(
        host,
        json!({"op":"play","log_id":log_id,"device_id":endpoint}),
    )
    .await?;
    if value["device"] != endpoint || value["log_id"] != log_id {
        return Err(bad());
    }
    let text = match value["delivery"].as_str() {
        Some("played_live") => "Played",
        Some("playing") => "Playing",
        Some("queued") => "Queued",
        _ => return Err(bad()),
    };
    number(&value["unheard_count"])?;
    Ok(Reply {
        messages: vec![PluginMsg::Status { text: text.into() }],
        page: None,
        failure: None,
    })
}

async fn delete(
    host: &HostLink,
    args: Value,
    offset: u64,
    limit: u8,
    success: &str,
) -> Result<Reply, HostError> {
    let text = match call(host, args).await {
        Ok(_) => success,
        Err(HostError::Timeout) => "Deletion outcome unknown",
        Err(e) => return Err(e),
    };
    let mut reply = match page(host, offset, limit).await {
        Ok(reply) => reply,
        Err(e) => Reply {
            messages: vec![],
            page: None,
            failure: Some(e),
        },
    };
    reply
        .messages
        .insert(0, PluginMsg::Status { text: text.into() });
    Ok(reply)
}
