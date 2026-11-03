//! Session choices use the pinned public capabilities; no model turn is sent.
use crate::{
    fault::{string, Fault, Result},
    runtime::Runtime,
    turn,
};
use serde_json::{json, Value};

fn model<'a>(provider: &'a Value, id: &str) -> Result<&'a Value> {
    provider["models"]
        .as_array()
        .and_then(|models| models.iter().find(|model| model["id"] == id))
        .ok_or_else(|| {
            Fault::held(
                "model_unavailable",
                "Choose a model advertised by the owned T3 Codex instance.",
            )
        })
}

fn effort_descriptor(model: &Value) -> Option<&Value> {
    model["options"]
        .as_array()?
        .iter()
        .find(|option| option["id"] == "reasoningEffort")
}

fn effort(selection: &Value) -> Option<&str> {
    selection["options"]
        .as_array()?
        .iter()
        .find(|option| option["id"] == "reasoningEffort")?["value"]
        .as_str()
}

pub fn validate(runtime: &Runtime, selection: &Value) -> Result<()> {
    let provider = turn::codex_provider(runtime)?;
    if selection["instanceId"] != provider["providerInstanceId"] {
        return Err(Fault::held(
            "model_unavailable",
            "Session selection must use the owned T3 Codex instance.",
        ));
    }
    let advertised = model(provider, string(selection, "model")?)?;
    if let Some(options) = selection.get("options") {
        let options = options
            .as_array()
            .ok_or_else(|| Fault::held("invalid_selection", "Model options must be an array."))?;
        let efforts: Vec<&Value> = options
            .iter()
            .filter(|option| option["id"] == "reasoningEffort")
            .collect();
        if efforts.len() > 1 {
            return Err(Fault::held(
                "invalid_selection",
                "Reasoning effort must be selected once.",
            ));
        }
        if let Some(selected) = efforts.first() {
            let value = string(selected, "value")?;
            if !effort_descriptor(advertised)
                .and_then(|option| option["values"].as_array())
                .is_some_and(|values| values.iter().any(|entry| entry.as_str() == Some(value)))
            {
                return Err(Fault::held("effort_unavailable", "This model does not advertise that reasoning effort. Omit effort when its support is unverified."));
            }
        }
    }
    Ok(())
}

fn with_effort(mut selection: Value, selected: Option<&str>) -> Result<Value> {
    if let Some(selected) = selected {
        let mut options = match selection.get("options") {
            Some(value) => value.as_array().cloned().ok_or_else(|| {
                Fault::held("invalid_selection", "Model options must be an array.")
            })?,
            None => Vec::new(),
        };
        options.retain(|option| option["id"] != "reasoningEffort");
        options.push(json!({"id":"reasoningEffort","value":selected}));
        selection["options"] = json!(options);
    }
    Ok(selection)
}

pub fn options(runtime: &Runtime) -> Result<Value> {
    let provider = turn::codex_provider(runtime)?;
    let models = provider["models"]
        .as_array()
        .filter(|models| !models.is_empty())
        .ok_or_else(|| {
            Fault::held(
                "codex_unavailable",
                "T3 advertised no available Codex model.",
            )
        })?;
    let project = turn::project(runtime, &runtime.receipt.workspace)?;
    let mut default = project
        .as_ref()
        .map(|project| project["defaultModelSelection"].clone())
        .unwrap_or(Value::Null);
    if default.is_null() {
        default =
            json!({"instanceId":provider["providerInstanceId"],"model":string(&models[0], "id")?});
    }
    let default_error = (|| -> Result<()> {
        let default_model = model(provider, string(&default, "model")?)?;
        if effort(&default).is_none() {
            default = with_effort(
                default.clone(),
                effort_descriptor(default_model).and_then(|option| option["default"].as_str()),
            )?;
        }
        validate(runtime, &default)
    })()
    .err()
    .map(|fault| fault.text);
    if default_error.is_some() {
        default = Value::Null;
    }
    let models: Vec<Value> = models.iter().map(|model| {
        let descriptor = effort_descriptor(model);
        json!({"id":model["id"],"label":model.get("label").unwrap_or(&model["id"]),
            "efforts":descriptor.and_then(|option| option["values"].as_array()).map(|values| values.iter().filter_map(Value::as_str).collect::<Vec<_>>()),
            "default_effort":descriptor.and_then(|option| option["default"].as_str()),
            "effort_support":if descriptor.is_some(){"advertised"}else{"unverified"}})
    }).collect();
    Ok(
        json!({"available":true,"workspace":runtime.receipt.workspace,"registered":project.is_some(),
        "harness":"Codex","instance_id":provider["providerInstanceId"],"runtime_mode":"approval-required",
        "models":models,"omitted_models":provider["omittedModels"],"default":default,"default_error":default_error}),
    )
}

pub fn selection(runtime: &Runtime, args: &Value) -> Result<Value> {
    let available = options(runtime)?;
    let default = &available["default"];
    let requested_model = match args.get("model") {
        None => default["model"].as_str().ok_or_else(|| Fault::held("model_unavailable", "The project default is not an advertised Codex selection. Choose a listed model explicitly."))?,
        Some(value) => value
            .as_str()
            .filter(|value| !value.is_empty() && value.len() <= 256)
            .ok_or_else(|| {
                Fault::held(
                    "invalid_selection",
                    "model must be a nonempty string of at most256 bytes.",
                )
            })?,
    };
    let provider = turn::codex_provider(runtime)?;
    let advertised = model(provider, requested_model)?;
    let selected = if default["model"] == requested_model {
        default.clone()
    } else {
        json!({"instanceId":provider["providerInstanceId"],"model":requested_model})
    };
    let requested_effort = match args.get("effort") {
        None => effort(&selected).or_else(|| effort_descriptor(advertised).and_then(|option| option["default"].as_str())),
        Some(value) => Some(value.as_str().filter(|value| !value.is_empty() && value.len() <= 64)
            .ok_or_else(|| Fault::held("invalid_selection", "effort must be a nonempty string of at most64 bytes; omit it to use the default."))?),
    };
    let selected = with_effort(selected.clone(), requested_effort)?;
    validate(runtime, &selected)?;
    Ok(selected)
}

pub fn confirmed(chat_id: &str, workspace: &str, selection: &Value, registration: Value) -> Value {
    let effort = effort(selection).unwrap_or("default");
    json!({"success":true,"chat_id":chat_id,"workspace":workspace,"registered":true,
        "harness":"Codex","model":selection["model"],"effort":effort,"model_selection":selection,
        "runtime_mode":"approval-required","registration":registration,
        "display_name":format!("T3 Code · Codex · {} · {effort}",selection["model"].as_str().unwrap_or(""))})
}
