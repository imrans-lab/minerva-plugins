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
        include_str!("fixtures/mouse_panel.gd"),
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
