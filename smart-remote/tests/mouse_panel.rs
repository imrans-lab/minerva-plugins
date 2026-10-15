#![cfg(target_os = "linux")]
//! One happy path across real BlueZ D-Bus, plugin stdio and Minerva panel IPC.
use dbus::{
    arg::{PropMap, Variant},
    blocking::Connection,
    channel::{MatchingReceiver, Sender},
    message::MatchRule,
    Path,
};
use std::{
    collections::HashMap,
    io::{BufRead, BufReader},
    process::{Child, Command, Stdio},
    sync::{
        atomic::{AtomicBool, Ordering},
        Arc,
    },
    time::{Duration, Instant},
};

struct Process(Child);
impl Drop for Process {
    fn drop(&mut self) {
        let _ = self.0.kill();
        let _ = self.0.wait();
    }
}

#[test]
#[ignore = "requires MINERVA_TEST_PROJECT and matching Godot/native extensions"]
fn bonded_mouse_is_visible_through_real_plugin_and_minerva_panel() {
    let project = std::env::var("MINERVA_TEST_PROJECT").expect("isolated Minerva project");
    let mut bus = Process(
        Command::new("dbus-daemon")
            .args(["--session", "--nofork", "--print-address=1"])
            .stdout(Stdio::piped())
            .spawn()
            .unwrap(),
    );
    let mut address = String::new();
    BufReader::new(bus.0.stdout.take().unwrap())
        .read_line(&mut address)
        .unwrap();
    let address = address.trim().to_owned();
    let ready = Arc::new(AtomicBool::new(false));
    let stop = Arc::new(AtomicBool::new(false));
    let (server_address, server_ready, server_stop) =
        (address.clone(), ready.clone(), stop.clone());
    let server = std::thread::spawn(move || {
        let connection = Connection::new_address(&server_address).unwrap();
        connection
            .request_name("org.bluez", false, true, false)
            .unwrap();
        connection.start_receive(
            MatchRule::new_method_call(),
            Box::new(|message, connection| {
                if message.member().is_some_and(|m| m == "GetManagedObjects") {
                    let properties: PropMap = HashMap::from([
                        (
                            "Name".into(),
                            Variant(Box::new("Smart Remote V2".to_owned())
                                as Box<dyn dbus::arg::RefArg>),
                        ),
                        ("Bonded".into(), Variant(Box::new(true))),
                        ("Paired".into(), Variant(Box::new(true))),
                        (
                            "UUIDs".into(),
                            Variant(Box::new(vec![
                                "00001812-0000-1000-8000-00805f9b34fb".to_owned()
                            ])),
                        ),
                    ]);
                    let objects = HashMap::from([(
                        Path::new("/org/bluez/hci0/dev_AA_BB_CC_DD_EE_FF").unwrap(),
                        HashMap::from([("org.bluez.Device1".to_owned(), properties)]),
                    )]);
                    connection
                        .send(message.method_return().append1(objects))
                        .unwrap();
                }
                true
            }),
        );
        server_ready.store(true, Ordering::Release);
        while !server_stop.load(Ordering::Acquire) {
            connection.process(Duration::from_millis(50)).unwrap();
        }
    });
    let deadline = Instant::now() + Duration::from_secs(5);
    while !ready.load(Ordering::Acquire) {
        assert!(Instant::now() < deadline);
        std::thread::sleep(Duration::from_millis(10));
    }
    std::fs::write(
        format!("{project}/test/test_smart_remote_mouse_setup.gd"),
        PANEL_FIXTURE,
    )
    .unwrap();
    let mut godot = Command::new(std::env::var("SMART_REMOTE_GODOT").unwrap_or("godot".into()))
        .args([
            "--headless",
            "--path",
            &project,
            "--script",
            "res://test/test_smart_remote_mouse_setup.gd",
        ])
        .env("SMART_REMOTE_TEST_BUS", &address)
        .env("SMART_REMOTE_PLUGIN_ROOT", env!("CARGO_MANIFEST_DIR"))
        .env(
            "SMART_REMOTE_PLUGIN_BIN",
            env!("CARGO_BIN_EXE_smart-remote-plugin"),
        )
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .unwrap();
    let deadline = Instant::now() + Duration::from_secs(40);
    while godot.try_wait().unwrap().is_none() && Instant::now() < deadline {
        std::thread::sleep(Duration::from_millis(20));
    }
    if godot.try_wait().unwrap().is_none() {
        godot.kill().unwrap();
    }
    let output = godot.wait_with_output().unwrap();
    stop.store(true, Ordering::Release);
    server.join().unwrap();
    let stdout = String::from_utf8_lossy(&output.stdout);
    let stderr = String::from_utf8_lossy(&output.stderr);
    assert!(
        output.status.success()
            && stdout.contains("MOUSE_SETUP_PASS")
            && !stderr.contains("SCRIPT ERROR"),
        "{stdout}\n{stderr}"
    );
}

const PANEL_FIXTURE: &str = r###"extends SceneTree
## One combined-pin happy path, against the actual plugin and broker.

func _initialize() -> void:
	_run.call_deferred()

func _run() -> void:
	await process_frame
	var plugin_root := OS.get_environment("SMART_REMOTE_PLUGIN_ROOT")
	var definition_type = load("res://Scripts/Services/Plugins/PluginDefinition.gd")
	var definition = definition_type.from_manifest(plugin_root.path_join("manifest.json"))
	var manager = load("res://Scripts/Services/Plugins/PluginManager.gd").new()
	manager._db = load("res://Scripts/Services/Plugins/PluginDB.gd").new()
	definition.state = definition_type.State.RUNNING
	manager._db._plugins[definition.id] = definition
	var connection = load("res://Scripts/Services/MCP/MCPServerConnection.gd").new(definition.id)
	connection.configure_stdio("/usr/bin/env", ["DBUS_SYSTEM_BUS_ADDRESS=" + OS.get_environment("SMART_REMOTE_TEST_BUS"),
		OS.get_environment("SMART_REMOTE_PLUGIN_BIN"), "--data-dir", ProjectSettings.globalize_path("user://mouse-plugin"),
		"--bind", "127.0.0.1", "--port", "0", "--no-mdns"])
	if await connection.connect_to_server() != OK:
		quit(1)
		return
	manager._runtime[definition.id] = {"connection": connection}
	var policy = load("res://Scripts/Services/Plugins/PluginPolicy.gd").new()
	var capabilities = load("res://Scripts/Services/Plugins/CapabilityBroker.gd").new(policy)
	var broker = load("res://Scripts/Services/Plugins/PluginScenePanelBroker.gd").new(manager, policy, capabilities)
	# The unchanged panel loader uses plugin-owned scene files. Copy into this
	# disposable profile so relative scene scripts resolve normally.
	var directory := ProjectSettings.globalize_path("user://mouse-ui")
	DirAccess.make_dir_recursive_absolute(directory)
	for file: String in ["PairingPanel.tscn", "pairing_panel.gd"]:
		DirAccess.copy_absolute(plugin_root.path_join("ui").path_join(file), directory.path_join(file))
	var panel: Control = load("user://mouse-ui/PairingPanel.tscn").instantiate()
	root.add_child(panel)
	broker.register_panel(panel, definition.id, "mouse-panel", PackedStringArray(["minerva_smart_remote_pairing"]), "smart_remote_pairing")
	panel.call("_on_panel_loaded", {})
	var deadline := Time.get_ticks_msec() + 10000
	while panel.get_node("MouseStatus").text != "Mouse paired: yes" and Time.get_ticks_msec() < deadline:
		await process_frame
	var passed: bool = panel.get_node("MouseStatus").text == "Mouse paired: yes" and panel.get_node("MouseInstructions").text.contains("Smart Remote V2")
	panel.call("_on_panel_unload")
	broker.unregister_panel(definition.id, "mouse-panel")
	connection.disconnect_from_server()
	manager._runtime.clear()
	panel.free()
	manager.free()
	print("MOUSE_SETUP_PASS" if passed else "MOUSE_SETUP_FAIL")
	quit(0 if passed else 1)
"###;
