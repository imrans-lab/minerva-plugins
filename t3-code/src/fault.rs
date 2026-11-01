use serde_json::{json, Value};

pub type Result<T> = std::result::Result<T, Fault>;

pub struct Fault {
    pub code: &'static str,
    pub text: String,
    pub held: bool,
    pub definite_refusal: bool,
    pub prior_operation: Option<(String, Option<String>)>,
}

impl Fault {
    pub fn new(code: &'static str, text: impl Into<String>) -> Self {
        Self {
            code,
            text: text.into(),
            held: false,
            definite_refusal: false,
            prior_operation: None,
        }
    }

    pub fn held(code: &'static str, text: impl Into<String>) -> Self {
        Self {
            code,
            text: text.into(),
            held: true,
            definite_refusal: false,
            prior_operation: None,
        }
    }

    pub fn refused(code: &'static str, text: impl Into<String>) -> Self {
        Self {
            code,
            text: text.into(),
            held: true,
            definite_refusal: true,
            prior_operation: None,
        }
    }

    pub fn reply(&self) -> Value {
        let mut reply = json!({"kind": "error", "code": self.code, "text": self.text,
            "held": self.held, "hold_reason": if self.held { self.code } else { "" }});
        if let Some((token, run)) = &self.prior_operation {
            reply["prior_operation_token"] = json!(token);
            reply["prior_run_id"] = json!(run);
            reply["hold_reason"] = json!(format!(
                "{}:{token}:{}",
                self.code,
                run.as_deref().unwrap_or("unconfirmed")
            ));
        }
        reply
    }
}

impl From<std::io::Error> for Fault {
    fn from(error: std::io::Error) -> Self {
        Self::held(
            "private_state",
            format!("Cannot access private plugin state: {error}"),
        )
    }
}

impl From<serde_json::Error> for Fault {
    fn from(_: serde_json::Error) -> Self {
        Self::held("invalid_state", "Private state or a public T3 response has an invalid JSON shape. Nothing will be reconstructed or resent automatically.")
    }
}

pub fn string<'a>(value: &'a Value, field: &str) -> Result<&'a str> {
    value[field]
        .as_str()
        .filter(|s| !s.is_empty())
        .ok_or_else(|| {
            Fault::new(
                "contract_mismatch",
                format!("T3 response is missing {field}."),
            )
        })
}
