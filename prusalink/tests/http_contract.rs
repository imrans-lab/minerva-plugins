//! Loopback protocol checks using public RFC example credentials, never a real
//! printer/vault. These do not replace owner acceptance against PrusaLink.
use std::io::{Read, Write};
use std::net::{TcpListener, TcpStream};
use std::path::PathBuf;
use std::thread;
use std::time::{Duration, SystemTime, UNIX_EPOCH};

use prusalink_plugin::client::{Client, Password};
use prusalink_plugin::config::Printer;

fn request(stream: &mut TcpStream) -> (String, Vec<u8>) {
    stream
        .set_read_timeout(Some(Duration::from_secs(5)))
        .unwrap();
    let mut bytes = Vec::new();
    let mut byte = [0; 1];
    while !bytes.ends_with(b"\r\n\r\n") {
        stream.read_exact(&mut byte).unwrap();
        bytes.push(byte[0]);
        assert!(bytes.len() < 16 * 1024);
    }
    let headers = String::from_utf8(bytes).unwrap();
    let length = headers
        .lines()
        .find_map(|line| {
            let (key, value) = line.split_once(':')?;
            key.eq_ignore_ascii_case("content-length")
                .then(|| value.trim().parse::<usize>().unwrap())
        })
        .unwrap_or(0);
    let mut body = vec![0; length];
    stream.read_exact(&mut body).unwrap();
    (headers, body)
}
fn header_value<'a>(headers: &'a str, name: &str) -> Option<&'a str> {
    headers.lines().find_map(|line| {
        let (key, value) = line.split_once(':')?;
        key.eq_ignore_ascii_case(name).then(|| value.trim())
    })
}
fn reply(stream: &mut TcpStream, code: &str, headers: &str, body: &str) {
    write!(stream, "HTTP/1.1 {code}\r\nConnection: close\r\nContent-Length: {}\r\nContent-Type: application/json\r\n{headers}\r\n{body}",body.len()).unwrap();
    stream.flush().unwrap();
}
fn exchange(listener: &TcpListener, path: &str, body: &str, challenge: bool) {
    let (mut stream, _) = listener.accept().unwrap();
    let (headers, _) = request(&mut stream);
    assert!(
        headers.starts_with(&format!("GET {path} HTTP/1.1\r\n")),
        "{headers}"
    );
    if challenge {
        assert!(!headers.contains("Authorization:"));
        reply(&mut stream,"401 Unauthorized","WWW-Authenticate: Digest realm=\"Printer API\", nonce=\"public-rfc-test-nonce\", qop=\"auth\", algorithm=MD5\r\n", "");
    } else {
        assert!(header_value(&headers, "Authorization")
            .is_some_and(|value| value.starts_with("Digest ")));
        assert!(headers.contains(&format!("uri=\"{path}\"")));
        assert!(!headers.contains("Circle Of Life"));
        reply(
            &mut stream,
            if body.is_empty() {
                "204 No Content"
            } else {
                "200 OK"
            },
            "",
            body,
        );
    }
}
fn status_sequence(listener: &TcpListener, state: &str) {
    exchange(listener, "/api/version", "", true);
    exchange(
        listener,
        "/api/v1/status",
        &format!(
            r#"{{"printer":{{"state":"{state}","temp_nozzle":24,"target_nozzle":0,"temp_bed":25,"axis_z":0,"fan_hotend":0,"speed":100,"flow":100}}}}"#
        ),
        false,
    );
    exchange(listener, "/api/v1/job", "", false);
    exchange(
        listener,
        "/api/v1/storage",
        r#"{"storage_list":[{"path":"/usb/","available":true,"read_only":false,"free_space":12345678}]}"#,
        false,
    );
}
fn client(listener: &TcpListener) -> Client {
    Client::new(
        Printer {
            slot: 1,
            name: "Protocol test".into(),
            host: format!("http://{}", listener.local_addr().unwrap()),
            user: "Mufasa".into(),
        },
        Password::new("Circle Of Life".into()).unwrap(),
    )
    .unwrap()
}
fn file() -> PathBuf {
    let unique = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap()
        .as_nanos();
    let path = std::env::temp_dir().join(format!("prusalink-public-protocol-{unique}.bgcode"));
    std::fs::write(&path, b"public protocol bytes").unwrap();
    path
}
#[test]
fn upload_streams_without_start_or_overwrite_and_busy_start_is_refused() {
    let listener = TcpListener::bind("127.0.0.1:0").unwrap();
    let mut client = client(&listener);
    let server = thread::spawn(move || {
        status_sequence(&listener, "PRINTING");
        let (mut stream, _) = listener.accept().unwrap();
        let (headers, body) = request(&mut stream);
        assert!(headers.starts_with("PUT /api/v1/files/usb/"));
        assert_eq!(header_value(&headers, "Print-After-Upload"), Some("?0"));
        assert_eq!(header_value(&headers, "Overwrite"), Some("?0"));
        assert_eq!(
            header_value(&headers, "Content-Type"),
            Some("application/octet-stream")
        );
        assert_eq!(body, b"public protocol bytes");
        reply(&mut stream, "201 Created", "", "");
    });
    assert_eq!(
        client.upload(&file(), false).unwrap()["start_requested"],
        false
    );
    server.join().unwrap();
    let listener = TcpListener::bind("127.0.0.1:0").unwrap();
    let mut client = crate::client(&listener);
    let server = thread::spawn(move || {
        status_sequence(&listener, "PRINTING");
        listener.set_nonblocking(true).unwrap();
        thread::sleep(Duration::from_millis(50));
        assert!(
            listener.accept().is_err(),
            "no start/upload mutation after failed state guard"
        );
    });
    assert!(client.upload(&file(), true).is_err());
    server.join().unwrap();
}
