//! protocol.md rules that JSON Schema cannot state: frame size caps, the
//! U+0000 ban and the nesting-depth limit.
//!
//! Depth counts the way `protocol/tools/check_examples.py` does: the top-level
//! object is depth 1 and every value inside a container is one deeper, so a
//! scalar nested in eight containers is already too deep.

use std::fmt;

use serde_json::Value;

pub const MAX_DEPTH: usize = 8;
/// Device→plugin text frames.
pub const DEVICE_TEXT_MAX: usize = 4 * 1024;
/// Plugin→device text frames.
pub const PLUGIN_TEXT_MAX: usize = 8 * 1024;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ContractViolation {
    TooDeep,
    NulInString,
    NulInPropertyName,
}

impl fmt::Display for ContractViolation {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(match self {
            Self::TooDeep => "JSON nesting deeper than 8",
            Self::NulInString => "U+0000 in a string",
            Self::NulInPropertyName => "U+0000 in a property name",
        })
    }
}

impl std::error::Error for ContractViolation {}

/// Checks a decoded message. serde_json decodes an escaped `\u0000` into a
/// real U+0000 in both strings and keys, so this one check covers the raw and
/// escaped forms; raw control characters never reach here because serde_json
/// rejects them inside strings.
pub fn check(value: &Value) -> Result<(), ContractViolation> {
    walk(value, 1)
}

fn walk(value: &Value, depth: usize) -> Result<(), ContractViolation> {
    if depth > MAX_DEPTH {
        return Err(ContractViolation::TooDeep);
    }
    match value {
        Value::String(s) if s.contains('\0') => Err(ContractViolation::NulInString),
        Value::Object(map) => {
            for (key, child) in map {
                if key.contains('\0') {
                    return Err(ContractViolation::NulInPropertyName);
                }
                walk(child, depth + 1)?;
            }
            Ok(())
        }
        Value::Array(items) => items.iter().try_for_each(|item| walk(item, depth + 1)),
        _ => Ok(()),
    }
}

/// Removes U+0000 from every string and property name, as protocol.md
/// requires of any text the plugin sends.
pub fn strip_nul(value: &mut Value) {
    match value {
        Value::String(s) if s.contains('\0') => s.retain(|c| c != '\0'),
        Value::Object(map) => {
            if map.keys().any(|k| k.contains('\0')) {
                let old = std::mem::take(map);
                for (mut key, child) in old {
                    key.retain(|c| c != '\0');
                    map.insert(key, child);
                }
            }
            map.values_mut().for_each(strip_nul);
        }
        Value::Array(items) => items.iter_mut().for_each(strip_nul),
        _ => {}
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    fn nested(depth: usize) -> Value {
        let mut v = json!(1);
        for _ in 1..depth {
            v = json!([v]);
        }
        v
    }

    #[test]
    fn depth_limit_is_eight_counting_the_scalar() {
        assert_eq!(check(&nested(8)), Ok(()));
        assert_eq!(check(&nested(9)), Err(ContractViolation::TooDeep));
        let deep_object = json!({"a":{"b":{"c":{"d":{"e":{"f":{"g":{"h": 1}}}}}}}});
        assert_eq!(check(&deep_object), Err(ContractViolation::TooDeep));
    }

    #[test]
    fn escaped_nul_survives_decoding_and_is_caught() {
        let in_string: Value = serde_json::from_str(r#"{"type":"x","t":"a\u0000b"}"#).unwrap();
        assert_eq!(check(&in_string), Err(ContractViolation::NulInString));
        let in_key: Value = serde_json::from_str(r#"{"type":"x","k\u0000":1}"#).unwrap();
        assert_eq!(check(&in_key), Err(ContractViolation::NulInPropertyName));
        let in_array: Value = serde_json::from_str(r#"{"a":["ok","\u0000"]}"#).unwrap();
        assert_eq!(check(&in_array), Err(ContractViolation::NulInString));
    }

    #[test]
    fn raw_nul_is_not_json() {
        assert!(serde_json::from_str::<Value>("{\"t\":\"a\0b\"}").is_err());
    }

    #[test]
    fn strip_nul_cleans_strings_and_keys() {
        let mut v: Value =
            serde_json::from_str(r#"{"k\u0000":["a\u0000b",{"x":"\u0000"}]}"#).unwrap();
        strip_nul(&mut v);
        assert_eq!(v, json!({"k":["ab",{"x":""}]}));
        assert_eq!(check(&v), Ok(()));
    }
}
