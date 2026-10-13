//! Validators for the authoritative message schemas in `protocol/schema/`.
//!
//! The schema files are embedded at build time from the protocol directory
//! itself, so the plugin never carries a second copy; `build.rs` reruns the
//! build when any of them changes. A message's schema is the file named after
//! its `type` under `device/` (device→plugin) or `plugin/` (plugin→device),
//! the same lookup `protocol/tools/check_examples.py` uses.

use std::collections::HashMap;
use std::fmt;

use include_dir::{include_dir, Dir, File};
use jsonschema::{Draft, Registry, Validator};
use serde_json::Value;

static SCHEMA_DIR: Dir<'static> = include_dir!("$CARGO_MANIFEST_DIR/../protocol/schema");

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum Direction {
    DeviceToPlugin,
    PluginToDevice,
}

impl Direction {
    fn subdir(self) -> &'static str {
        match self {
            Self::DeviceToPlugin => "device",
            Self::PluginToDevice => "plugin",
        }
    }
}

/// The embedded schemas could not be turned into validators. This is a build
/// defect, not a runtime input problem, but it is reported rather than
/// panicking so the binary can say what is wrong.
#[derive(Debug)]
pub enum SchemaError {
    Parse { path: String, message: String },
    MissingId { path: String },
    Registry(String),
    Build { path: String, message: String },
    Empty(Direction),
}

impl fmt::Display for SchemaError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::Parse { path, message } => write!(f, "schema {path} is not JSON: {message}"),
            Self::MissingId { path } => write!(f, "schema {path} has no string $id"),
            Self::Registry(message) => write!(f, "schema registry: {message}"),
            Self::Build { path, message } => write!(f, "schema {path} does not compile: {message}"),
            Self::Empty(direction) => write!(f, "no {} schemas embedded", direction.subdir()),
        }
    }
}

impl std::error::Error for SchemaError {}

/// Why a message failed its schema. Carries only names and JSON pointers,
/// never instance values, so it is safe to log and to send back to a device
/// even when the message held a pairing token.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum SchemaViolation {
    NotAnObject,
    MissingType,
    UnknownType,
    Invalid {
        type_name: String,
        instance_path: String,
    },
}

impl fmt::Display for SchemaViolation {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::NotAnObject => f.write_str("message is not a JSON object"),
            Self::MissingType => f.write_str("message has no string type"),
            Self::UnknownType => f.write_str("unknown message type"),
            Self::Invalid {
                type_name,
                instance_path,
            } => {
                let at = if instance_path.is_empty() {
                    "/"
                } else {
                    instance_path
                };
                write!(f, "{type_name} fails its schema at {at}")
            }
        }
    }
}

pub struct Schemas {
    device: HashMap<String, Validator>,
    plugin: HashMap<String, Validator>,
}

impl Schemas {
    pub fn load() -> Result<Self, SchemaError> {
        let mut files = Vec::new();
        collect_files(&SCHEMA_DIR, &mut files);
        let mut docs = Vec::with_capacity(files.len());
        for file in files {
            let path = file.path().to_string_lossy().into_owned();
            let doc: Value =
                serde_json::from_slice(file.contents()).map_err(|e| SchemaError::Parse {
                    path: path.clone(),
                    message: e.to_string(),
                })?;
            let id = doc
                .get("$id")
                .and_then(Value::as_str)
                .ok_or_else(|| SchemaError::MissingId { path: path.clone() })?
                .to_owned();
            docs.push((path, id, doc));
        }
        let registry = Registry::new()
            .draft(Draft::Draft202012)
            .extend(docs.iter().map(|(_, id, doc)| (id.as_str(), doc)))
            .and_then(|builder| builder.prepare())
            .map_err(|e| SchemaError::Registry(e.to_string()))?;

        let mut schemas = Self {
            device: HashMap::new(),
            plugin: HashMap::new(),
        };
        for (path, _, doc) in &docs {
            let Some((dir, stem)) = split_message_path(path) else {
                continue;
            };
            let validator = jsonschema::options()
                .with_draft(Draft::Draft202012)
                .with_registry(&registry)
                .build(doc)
                .map_err(|e| SchemaError::Build {
                    path: path.clone(),
                    message: e.to_string(),
                })?;
            let map = match dir {
                "device" => &mut schemas.device,
                "plugin" => &mut schemas.plugin,
                _ => continue,
            };
            map.insert(stem.to_owned(), validator);
        }
        for direction in [Direction::DeviceToPlugin, Direction::PluginToDevice] {
            if schemas.map(direction).is_empty() {
                return Err(SchemaError::Empty(direction));
            }
        }
        Ok(schemas)
    }

    fn map(&self, direction: Direction) -> &HashMap<String, Validator> {
        match direction {
            Direction::DeviceToPlugin => &self.device,
            Direction::PluginToDevice => &self.plugin,
        }
    }

    /// The message types defined for `direction`.
    pub fn types(&self, direction: Direction) -> impl Iterator<Item = &str> {
        self.map(direction).keys().map(String::as_str)
    }

    pub fn validate(&self, direction: Direction, message: &Value) -> Result<(), SchemaViolation> {
        let object = message.as_object().ok_or(SchemaViolation::NotAnObject)?;
        let type_name = object
            .get("type")
            .and_then(Value::as_str)
            .ok_or(SchemaViolation::MissingType)?;
        let validator = self
            .map(direction)
            .get(type_name)
            .ok_or(SchemaViolation::UnknownType)?;
        match validator.iter_errors(message).next() {
            None => Ok(()),
            Some(error) => Err(SchemaViolation::Invalid {
                type_name: type_name.to_owned(),
                instance_path: error.instance_path().to_string(),
            }),
        }
    }
}

fn collect_files<'a>(dir: &'a Dir<'a>, out: &mut Vec<&'a File<'a>>) {
    for file in dir.files() {
        if file.path().extension().is_some_and(|ext| ext == "json") {
            out.push(file);
        }
    }
    for sub in dir.dirs() {
        collect_files(sub, out);
    }
}

/// `device/hello.json` → `("device", "hello")`; `common.json` → None.
fn split_message_path(path: &str) -> Option<(&str, &str)> {
    let (dir, file) = path.split_once('/')?;
    let stem = file.strip_suffix(".json")?;
    (!stem.contains('/')).then_some((dir, stem))
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[test]
    fn every_embedded_schema_compiles_and_both_directions_exist() {
        let schemas = Schemas::load().expect("embedded schemas load");
        let mut device: Vec<_> = schemas.types(Direction::DeviceToPlugin).collect();
        device.sort_unstable();
        assert!(device.contains(&"hello"));
        assert!(schemas
            .types(Direction::PluginToDevice)
            .any(|t| t == "welcome"));
    }

    #[test]
    fn common_refs_resolve_offline() {
        let schemas = Schemas::load().unwrap();
        let ok = json!({"type":"ptt_down","stream":255});
        assert_eq!(schemas.validate(Direction::DeviceToPlugin, &ok), Ok(()));
        let bad = json!({"type":"ptt_down","stream":256});
        assert!(matches!(
            schemas.validate(Direction::DeviceToPlugin, &bad),
            Err(SchemaViolation::Invalid { .. })
        ));
    }

    #[test]
    fn direction_matters() {
        let schemas = Schemas::load().unwrap();
        let welcome = json!({"type":"welcome","proto":1,"plugin":"x"});
        assert_eq!(
            schemas.validate(Direction::PluginToDevice, &welcome),
            Ok(())
        );
        assert_eq!(
            schemas.validate(Direction::DeviceToPlugin, &welcome),
            Err(SchemaViolation::UnknownType)
        );
    }

    #[test]
    fn violation_text_never_echoes_values() {
        let schemas = Schemas::load().unwrap();
        let hello = json!({"type":"hello","proto":1,"token":"short-secret","device_id":"a4cf12b03e5d","fw":"1"});
        let err = schemas
            .validate(Direction::DeviceToPlugin, &hello)
            .unwrap_err();
        assert!(!err.to_string().contains("short-secret"));
    }
}
