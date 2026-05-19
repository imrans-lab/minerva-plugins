// Integration tests for manifest.json correctness.
//
// Regression guards:
//   Bug 019e3c1906e4 — session_open_* tools missing input_schema
//   Bug 019e3c18ffef — state_changed event dropped from events array

use std::collections::HashMap;
use std::fs;
use std::path::PathBuf;

fn load_manifest() -> serde_json::Value {
    let manifest_dir = PathBuf::from(env!("CARGO_MANIFEST_DIR"));
    let path = manifest_dir.join("manifest.json");
    let text = fs::read_to_string(&path)
        .unwrap_or_else(|e| panic!("Failed to read manifest.json at {}: {}", path.display(), e));
    serde_json::from_str(&text)
        .unwrap_or_else(|e| panic!("manifest.json is not valid JSON: {}", e))
}

fn tools(manifest: &serde_json::Value) -> &Vec<serde_json::Value> {
    manifest["tools"]
        .as_array()
        .expect("manifest.json must have a top-level 'tools' array")
}

// ── Test 1: every tool has a name starting with minerva_scansort_ and all names are unique ──

#[test]
fn test_tool_names_prefix_and_unique() {
    let manifest = load_manifest();
    let tool_list = tools(&manifest);

    let mut seen: HashMap<&str, usize> = HashMap::new();

    for (i, tool) in tool_list.iter().enumerate() {
        let name = tool["name"]
            .as_str()
            .unwrap_or_else(|| panic!("Tool at index {} has no 'name' field", i));

        assert!(
            name.starts_with("minerva_scansort_"),
            "Tool at index {} has name '{}' which does not start with 'minerva_scansort_'",
            i,
            name
        );

        if let Some(prev) = seen.get(name) {
            panic!(
                "Duplicate tool name '{}' at indices {} and {}",
                name, prev, i
            );
        }
        seen.insert(name, i);
    }
}

// ── Test 2: session_open_* tools have correct input_schema (regression: Bug 019e3c1906e4) ──

#[test]
fn test_session_open_tools_have_input_schema() {
    let manifest = load_manifest();
    let tool_list = tools(&manifest);

    let session_open_tools = [
        "minerva_scansort_session_open_source",
        "minerva_scansort_session_open_directory",
        "minerva_scansort_session_open_vault",
    ];

    for target in &session_open_tools {
        let tool = tool_list
            .iter()
            .find(|t| t["name"].as_str() == Some(target))
            .unwrap_or_else(|| panic!("Tool '{}' not found in manifest.json", target));

        let schema = tool.get("input_schema").unwrap_or_else(|| {
            panic!(
                "Tool '{}' is missing 'input_schema' — regression guard for Bug 019e3c1906e4",
                target
            )
        });

        assert_eq!(
            schema["type"].as_str(),
            Some("object"),
            "Tool '{}' input_schema.type must be 'object', got: {:?}",
            target,
            schema["type"]
        );

        let props = schema["properties"]
            .as_object()
            .unwrap_or_else(|| {
                panic!(
                    "Tool '{}' input_schema.properties must be a non-empty object",
                    target
                )
            });

        assert!(
            !props.is_empty(),
            "Tool '{}' input_schema.properties must not be empty",
            target
        );

        let required = schema["required"]
            .as_array()
            .unwrap_or_else(|| {
                panic!(
                    "Tool '{}' input_schema.required must be an array",
                    target
                )
            });

        let required_strs: Vec<&str> = required
            .iter()
            .filter_map(|v| v.as_str())
            .collect();

        assert!(
            required_strs.contains(&"label"),
            "Tool '{}' input_schema.required must contain 'label', got: {:?}",
            target,
            required_strs
        );

        assert!(
            required_strs.contains(&"path"),
            "Tool '{}' input_schema.required must contain 'path', got: {:?}",
            target,
            required_strs
        );
    }
}

// ── Test 3: events array contains state_changed (regression: Bug 019e3c18ffef) ──

#[test]
fn test_events_contains_state_changed() {
    let manifest = load_manifest();

    let events = manifest["events"]
        .as_array()
        .expect("manifest.json must have a top-level 'events' array");

    let has_state_changed = events
        .iter()
        .any(|e| e["name"].as_str() == Some("state_changed"));

    assert!(
        has_state_changed,
        "manifest.json events array must contain an entry with name 'state_changed' — \
         regression guard for Bug 019e3c18ffef. Current events: {:?}",
        events
            .iter()
            .filter_map(|e| e["name"].as_str())
            .collect::<Vec<_>>()
    );
}

// ── Test 4: DCR 019e3d67 session_reset is registered ──

#[test]
fn test_session_reset_tool_present() {
    let manifest = load_manifest();
    let tool_list = tools(&manifest);
    let found = tool_list
        .iter()
        .any(|t| t["name"].as_str() == Some("minerva_scansort_session_reset"));
    assert!(
        found,
        "manifest.json must register 'minerva_scansort_session_reset' — \
         regression guard for DCR 019e3d67."
    );
}

// ── Test 5: DCR 019e41a5 clear_source_cache is registered ──

#[test]
fn test_clear_source_cache_tool_present() {
    let manifest = load_manifest();
    let tool_list = tools(&manifest);
    let found = tool_list
        .iter()
        .any(|t| t["name"].as_str() == Some("minerva_scansort_clear_source_cache"));
    assert!(
        found,
        "manifest.json must register 'minerva_scansort_clear_source_cache' — \
         regression guard for DCR 019e41a5."
    );
}

// ── Test 6: every manifest tool name has a handler in main.rs ──
//
// We grep src/main.rs for `"minerva_scansort_…" =>` match arms and verify
// each manifest tool appears at least once.

#[test]
fn test_manifest_tools_have_handlers_in_main_rs() {
    let manifest_dir = PathBuf::from(env!("CARGO_MANIFEST_DIR"));
    let main_rs_path = manifest_dir.join("src/main.rs");

    let main_rs = match fs::read_to_string(&main_rs_path) {
        Ok(s) => s,
        Err(_) => {
            // TODO L2: if main.rs can't be read, skip gracefully
            eprintln!("SKIP test_manifest_tools_have_handlers_in_main_rs: could not read src/main.rs");
            return;
        }
    };

    let manifest = load_manifest();
    let tool_list = tools(&manifest);

    let mut missing: Vec<&str> = Vec::new();

    for tool in tool_list.iter() {
        let name = tool["name"].as_str().expect("tool has name");
        // Look for the tool name as a string literal followed by " =>" in the match
        let pattern = format!("\"{}\" =>", name);
        if !main_rs.contains(&pattern) {
            missing.push(name);
        }
    }

    assert!(
        missing.is_empty(),
        "The following manifest tools have no '\"<name>\" =>' dispatch arm in src/main.rs: {:?}",
        missing
    );
}
