//! The pinned public input surface, shared with T2's turn implementation.

use serde::Deserialize;
use serde_json::{json, Value};
use std::collections::BTreeMap;

#[derive(Clone, Deserialize)]
pub struct Contract {
    pub t3_tag: String,
    pub t3_commit: String,
    pub node_engine: String,
    pub tools: BTreeMap<String, Vec<String>>,
}

impl Contract {
    pub fn compatibility(&self, detected_versions: Value) -> Value {
        json!({
            "plugin_version": env!("CARGO_PKG_VERSION"), "t3_tag": self.t3_tag,
            "t3_commit": self.t3_commit, "detected_versions": detected_versions,
            "auth_path": "public CLI mcp-client bearer", "access_ceiling": "approval-required",
            "home_strategy": "owner login in place; never copied",
            "runtime_mode": "not-started", "runtime_policy": "explicit approval-required on launch"
        })
    }

    pub fn embedded() -> Result<Self, String> {
        serde_json::from_str(include_str!("../t3-contract.json"))
            .map_err(|e| format!("Invalid embedded T3 contract: {e}"))
    }

    pub fn check_catalog(&self, catalog: &Value) -> Result<(), String> {
        let tools = catalog
            .get("tools")
            .or_else(|| catalog.get("result").and_then(|r| r.get("tools")))
            .and_then(Value::as_array)
            .ok_or("T3 tools/list did not return a tools array")?;
        for (name, fields) in &self.tools {
            let matches: Vec<&Value> = tools.iter().filter(|tool| tool["name"] == *name).collect();
            if matches.len() != 1 {
                return Err(format!("T3 {} requires exactly one {name} tool; found {}. Use the supported T3 release.", self.t3_tag, matches.len()));
            }
            let schema = &matches[0]["inputSchema"];
            let properties = schema["properties"].as_object();
            for field in fields {
                if !properties.is_some_and(|properties| properties.contains_key(field)) {
                    return Err(format!(
                        "{name}: required input property {field} is missing. Use T3 {}.",
                        self.t3_tag
                    ));
                }
            }
            if let Some(required) = schema.get("required") {
                for value in required
                    .as_array()
                    .ok_or_else(|| format!("{name}: malformed required list"))?
                {
                    let field = value
                        .as_str()
                        .ok_or_else(|| format!("{name}: malformed required field"))?;
                    if !fields.iter().any(|supplied| supplied == field) {
                        return Err(format!(
                            "{name}: T3 now requires unsupported argument {field}. Use T3 {}.",
                            self.t3_tag
                        ));
                    }
                }
            }
        }
        Ok(())
    }
}
