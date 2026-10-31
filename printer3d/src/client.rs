//! Prusa's published v1 API, with fresh per-tool vault credentials and no redirects.
use std::fs::File;
use std::io::Read;
use std::path::Path;
use std::sync::mpsc;
use std::thread;
use std::time::{Duration, Instant};

use base64::Engine;
use serde::Serialize;
use serde_json::Value;
use ureq::http::{request::Builder, Response};
use ureq::{AsSendBody, Body};
use url::Url;

use crate::config::{normalize_host, Printer};
use crate::digest::Challenge;
use crate::error::{Error, Result};

// Deliberately neither Debug nor Serialize: only Digest calculation may read it.
pub struct Password(String);
impl Password {
    pub fn new(value: String) -> Result<Self> {
        if value.is_empty() {
            return Err(Error::MissingPassword);
        }
        Ok(Self(value))
    }
}

pub fn agent(timeout: Duration) -> ureq::Agent {
    ureq::Agent::config_builder()
        .max_redirects(0)
        .proxy(None)
        .http_status_as_error(false)
        .max_idle_connections(0)
        .timeout_connect(Some(Duration::from_secs(3)))
        .timeout_per_read(Some(Duration::from_secs(5)))
        .timeout_per_write(Some(Duration::from_secs(15)))
        .timeout_global(Some(timeout))
        .build()
        .new_agent()
}
fn transport(error: ureq::Error, mutation: bool) -> Error {
    Error::Transport {
        mutation,
        connection: matches!(
            error,
            ureq::Error::ConnectionFailed | ureq::Error::HostNotFound
        ),
    }
}
fn response(
    result: std::result::Result<Response<Body>, ureq::Error>,
    mutation: bool,
) -> Result<Response<Body>> {
    let response = result.map_err(|error| transport(error, mutation))?;
    let status = response.status().as_u16();
    if status >= 400 {
        return Err(if mutation {
            Error::MutationHttp(status)
        } else {
            Error::Http(status)
        });
    }
    Ok(response)
}

/// Owns only this client's sockets; shutdown interrupts even partial-write loops.
struct UploadDeadline {
    cancel: mpsc::Sender<()>,
    worker: Option<thread::JoinHandle<()>>,
}
impl UploadDeadline {
    fn start(agent: ureq::Agent) -> Result<Self> {
        let (cancel, receiver) = mpsc::channel();
        let worker = thread::Builder::new()
            .name("printer3d-upload-deadline".into())
            .spawn(move || {
                if matches!(
                    receiver.recv_timeout(Duration::from_secs(20)),
                    Err(mpsc::RecvTimeoutError::Timeout)
                ) {
                    eprintln!("printer3d upload phase=network_deadline");
                    agent.shutdown();
                }
            })
            .map_err(|_| Error::Io("Cannot start upload deadline"))?;
        Ok(Self {
            cancel,
            worker: Some(worker),
        })
    }
}
impl Drop for UploadDeadline {
    fn drop(&mut self) {
        // A finished/disconnected timer needs no cancellation. Always join so no
        // deadline can fire against a later operation or retain owned sockets.
        let _ = self.cancel.send(());
        if let Some(worker) = self.worker.take() {
            if worker.join().is_err() {
                eprintln!("printer3d upload phase=deadline_worker_failed");
            }
        }
    }
}
fn json(response: Response<Body>) -> Result<Value> {
    let mut bytes = Vec::new();
    response
        .into_body()
        .into_reader()
        .take(1024 * 1024 + 1)
        .read_to_end(&mut bytes)
        .map_err(|_| Error::Protocol("Cannot read printer response"))?;
    if bytes.len() > 1024 * 1024 {
        return Err(Error::Protocol("Printer response exceeds1MiB"));
    }
    serde_json::from_slice(&bytes).map_err(|_| Error::Protocol("Printer returned invalid JSON"))
}

pub struct Client {
    printer: Printer,
    password: Password,
    agent: ureq::Agent,
    challenge: Option<Challenge>,
    nonce_count: u32,
    cnonce: String,
    upload_started: Option<Instant>,
    identity_started: Option<Instant>,
}
impl Client {
    pub fn new(printer: Printer, password: Password) -> Result<Self> {
        let mut nonce = [0_u8; 16];
        getrandom::fill(&mut nonce).map_err(|_| Error::Io("OS randomness unavailable"))?;
        Ok(Self {
            printer,
            password,
            agent: agent(Duration::from_secs(120)),
            challenge: None,
            upload_started: None,
            identity_started: None,
            nonce_count: 0,
            cnonce: nonce.iter().map(|b| format!("{b:02x}")).collect(),
        })
    }
    fn upload_phase(&self, phase: &str) {
        if let Some(started) = self.upload_started {
            // Fixed phase names and elapsed time only: never paths, bodies or credentials.
            eprintln!(
                "printer3d upload phase={phase} elapsed_ms={}",
                started.elapsed().as_millis()
            );
        }
    }
    fn request_timeout(&self) -> Result<Duration> {
        match self.upload_started {
            Some(started) => Duration::from_secs(20)
                .checked_sub(started.elapsed())
                .filter(|remaining| !remaining.is_zero())
                .ok_or(Error::Protocol(
                    "Upload preflight deadline exceeded; no upload was sent",
                )),
            None => match self.identity_started {
                Some(started) => Duration::from_secs(8)
                    .checked_sub(started.elapsed())
                    .filter(|remaining| !remaining.is_zero())
                    .ok_or(Error::Protocol("Printer identity read deadline exceeded")),
                None => Ok(Duration::from_secs(120)),
            },
        }
    }
    fn authenticate(&mut self) -> Result<()> {
        if self.challenge.is_some() {
            return Ok(());
        }
        for path in ["/api/version", "/api/v1/status"] {
            self.upload_phase("authenticate");
            let request = ureq::http::Request::builder()
                .method("GET")
                .uri(format!("{}{path}", self.printer.host));
            let result = self.execute(request, (), false, false)?;
            match result.status().as_u16() {
                401 => {
                    for header in result.headers().get_all("WWW-Authenticate") {
                        if let Ok(challenge) = header
                            .to_str()
                            .map_err(|_| Error::Protocol("Invalid authentication header"))
                            .and_then(Challenge::parse)
                        {
                            if challenge.realm == "Printer API" {
                                self.challenge = Some(challenge);
                                return Ok(());
                            }
                        }
                    }
                    return Err(Error::Protocol(
                        "Printer requires unsupported Digest authentication",
                    ));
                }
                200 => continue,
                status => return Err(Error::Http(status)),
            }
        }
        Err(Error::Protocol(
            "Printer did not provide a PrusaLink Digest challenge",
        ))
    }
    fn execute<S: AsSendBody>(
        &self,
        request: Builder,
        body: S,
        mutation: bool,
        check_status: bool,
    ) -> Result<Response<Body>> {
        let request = request
            .body(body)
            .map_err(|_| Error::Protocol("Cannot build printer request"))?;
        let request = self
            .agent
            .configure_request(request)
            .timeout_global(Some(self.request_timeout()?))
            .build();
        let result = self.agent.run(request);
        if check_status {
            response(result, mutation)
        } else {
            result.map_err(|error| transport(error, mutation))
        }
    }
    fn request(&mut self, method: &str, path: &str) -> Result<Builder> {
        self.authenticate()?;
        self.nonce_count = self
            .nonce_count
            .checked_add(1)
            .ok_or(Error::Protocol("Digest nonce count exhausted"))?;
        let challenge = self
            .challenge
            .as_ref()
            .ok_or(Error::Protocol("Digest challenge unavailable"))?;
        let authorization = challenge.authorization(
            method,
            path,
            &self.printer.user,
            &self.password.0,
            &self.cnonce,
            self.nonce_count,
        )?;
        Ok(ureq::http::Request::builder()
            .method(method)
            .uri(format!("{}{path}", self.printer.host))
            .header("Authorization", &authorization)
            .header("Accept", "application/json"))
    }
    fn get(&mut self, path: &str) -> Result<Value> {
        self.upload_phase(match path {
            "/api/v1/status" => "status",
            "/api/v1/job" => "job",
            "/api/v1/storage" => "storage",
            _ => "read",
        });
        let request = self.request("GET", path)?;
        let response = self.execute(request, (), false, true)?;
        if response.status() == 204 {
            return Ok(Value::Null);
        }
        json(response)
    }
    pub fn status(&mut self) -> Result<Status> {
        let data = self.get("/api/v1/status")?;
        let job = self.get("/api/v1/job")?;
        let storage = self.get("/api/v1/storage")?;
        project_status(&self.printer.id(), &data, &job, &storage)
    }
    /// Explicit configuration probe. Project only identity fields, never raw info/serials.
    pub fn slicing_identity(&mut self) -> Result<SlicingIdentity> {
        self.identity_started = Some(Instant::now());
        let result = (|| {
            let version = self.get("/api/version")?;
            let info = match self.get("/api/v1/info") {
                Err(Error::Http(404)) => Value::Null,
                result => result?,
            };
            let version_printer = match version.get("printer") {
                None | Some(Value::Null) => None,
                Some(Value::String(value))
                    if !value.is_empty()
                        && value.len() <= 256
                        && !value.chars().any(char::is_control) =>
                {
                    Some(value.clone())
                }
                _ => return Err(Error::Protocol("Invalid reported printer identity")),
            };
            Ok(SlicingIdentity {
                version_printer,
                version_nozzle_diameter: identity_nozzle(&version)?,
                info_nozzle_diameter: identity_nozzle(&info)?,
            })
        })();
        self.identity_started = None;
        result
    }
    pub fn thumbnail(&mut self, offset: usize, reference: Option<&str>) -> Result<Value> {
        let job = self.get("/api/v1/job")?;
        let Some(path) = thumbnail_path(&job["file"]["refs"]["thumbnail"]) else {
            return Ok(serde_json::json!({"available":false}));
        };
        if reference.is_some_and(|reference| reference != path) {
            return Err(Error::Protocol(
                "Current job thumbnail changed; request it again",
            ));
        }
        let request = self.request("GET", &path)?;
        let response = match self.execute(request, (), false, true) {
            Err(Error::Http(404)) => return Ok(serde_json::json!({"available":false})),
            other => other?,
        };
        let mut bytes = Vec::new();
        response
            .into_body()
            .into_reader()
            .take(512 * 1024 + 1)
            .read_to_end(&mut bytes)
            .map_err(|_| Error::Protocol("Cannot read thumbnail"))?;
        if bytes.len() > 512 * 1024 {
            return Err(Error::Protocol("Printer thumbnail exceeds512KiB"));
        }
        // Only raster image signatures. Never pass SVG/HTML supplied by the printer
        // into the embedded browser, regardless of its Content-Type header.
        let mime = if bytes.starts_with(b"\x89PNG\r\n\x1a\n") {
            "image/png"
        } else if bytes.starts_with(&[0xff, 0xd8, 0xff]) {
            "image/jpeg"
        } else {
            return Err(Error::Protocol("Unsupported printer thumbnail format"));
        };
        if offset >= bytes.len() || !offset.is_multiple_of(24 * 1024) {
            return Err(Error::Invalid("Thumbnail offset is out of range"));
        }
        let end = (offset + 24 * 1024).min(bytes.len());
        let encoded = base64::engine::general_purpose::STANDARD.encode(&bytes[offset..end]);
        Ok(
            serde_json::json!({"available":true,"mime":mime,"reference":path,"offset":offset,"total_bytes":bytes.len(),"base64":encoded,"next_offset":if end<bytes.len(){Some(end)}else{None}}),
        )
    }

    pub fn upload(&mut self, path: &Path, start: bool) -> Result<Value> {
        // One shared network budget covers authentication, status reads and PUT.
        // Leave headroom for the host MCP deadline. Never replay a mutation.
        let deadline = UploadDeadline::start(self.agent.clone())?;
        self.upload_started = Some(Instant::now());
        self.upload_phase("begin");
        let result = self.upload_inner(path, start);
        self.upload_phase(if result.is_ok() { "complete" } else { "failed" });
        drop(deadline);
        self.upload_started = None;
        self.agent = agent(Duration::from_secs(120));
        result
    }
    fn upload_inner(&mut self, path: &Path, start: bool) -> Result<Value> {
        let name = path
            .file_name()
            .and_then(|s| s.to_str())
            .ok_or(Error::Invalid("Upload path needs a UTF-8 filename"))?;
        let remote = file_path(name)?;
        let status = self.status()?;
        if !status.storage_available {
            return Err(Error::Http(507));
        }
        if status.storage_read_only {
            return Err(Error::Invalid("Printer USB storage is read-only"));
        }
        if start {
            ready(&status.state)?;
        }
        self.upload_phase("open_file");
        let file =
            File::open(path).map_err(|_| Error::Io("Cannot open the requested G-code file"))?;
        let metadata = file
            .metadata()
            .map_err(|_| Error::Io("Cannot inspect the requested G-code file"))?;
        if !metadata.is_file() || metadata.len() == 0 {
            return Err(Error::Invalid(
                "Upload needs a nonempty regular .bgcode or .gcode file",
            ));
        }
        let request = self
            .request("PUT", &remote)?
            .header("Content-Type", "application/octet-stream")
            .header("Content-Length", &metadata.len().to_string())
            .header("Print-After-Upload", if start { "?1" } else { "?0" })
            .header("Overwrite", "?0");
        self.upload_phase("send");
        let result = self.execute(request, file, true, true)?;
        if result.status() != 201 {
            return Err(Error::Protocol(
                "Printer did not confirm the upload; inspect its file list before retrying",
            ));
        }
        Ok(
            serde_json::json!({"printer":self.printer.id(),"file":name,"remote_name":name,"remote_path":remote,"uploaded":true,"start_requested":start,"overwrite":false}),
        )
    }
    pub fn print(&mut self, file: &str) -> Result<Value> {
        let path = file_path(file)?;
        ready(&self.status()?.state)?;
        let request = self.request("POST", &path)?;
        let result = self.execute(request, (), true, true)?;
        if result.status() != 204 {
            return Err(Error::Protocol(
                "Printer did not confirm print start; check the printer before retrying",
            ));
        }
        Ok(serde_json::json!({"printer":self.printer.id(),"file":file,"print_requested":true}))
    }
    pub fn stop(&mut self) -> Result<Value> {
        let status = self.status()?;
        if !matches!(status.state.as_str(), "PRINTING" | "PAUSED") {
            return Err(Error::Invalid("Stop requires a PRINTING or PAUSED printer"));
        }
        let id = match status.job_id {
            Some(id) => id,
            None => self.get("/api/v1/job")?["id"]
                .as_u64()
                .ok_or(Error::Protocol(
                    "Printer has no current job id; refusing to guess",
                ))?,
        };
        let request = self.request("DELETE", &format!("/api/v1/job/{id}"))?;
        let result = self.execute(request, (), true, true)?;
        if result.status() != 204 {
            return Err(Error::Protocol(
                "Printer did not confirm stop; check the printer before retrying",
            ));
        }
        Ok(serde_json::json!({"printer":self.printer.id(),"job_id":id,"stop_requested":true}))
    }
}

#[derive(Serialize)]
pub struct SlicingIdentity {
    pub version_printer: Option<String>,
    pub version_nozzle_diameter: Option<f64>,
    pub info_nozzle_diameter: Option<f64>,
}
fn identity_nozzle(value: &Value) -> Result<Option<f64>> {
    match value.get("nozzle_diameter") {
        None | Some(Value::Null) => Ok(None),
        Some(value) => value
            .as_f64()
            .filter(|value| value.is_finite() && *value > 0.0 && *value <= 2.0)
            .map(Some)
            .ok_or(Error::Protocol("Invalid reported nozzle diameter")),
    }
}

#[derive(Serialize)]
pub struct Status {
    pub printer: String,
    pub state: String,
    pub nozzle_c: Option<f64>,
    pub nozzle_target_c: Option<f64>,
    pub bed_c: Option<f64>,
    pub bed_target_c: Option<f64>,
    pub progress_percent: Option<f64>,
    pub time_printing_s: Option<u64>,
    pub time_remaining_s: Option<u64>,
    pub job_id: Option<u64>,
    pub job_file: Option<String>,
    pub thumbnail_ref: Option<String>,
    pub axis_z_mm: Option<f64>,
    pub total_height_mm: Option<f64>,
    pub layer_height_mm: Option<f64>,
    pub fan_hotend_rpm: Option<u64>,
    pub fan_print_rpm: Option<u64>,
    pub speed_percent: Option<f64>,
    pub flow_percent: Option<f64>,
    pub storage_available: bool,
    pub storage_read_only: bool,
    pub free_bytes: Option<u64>,
}
fn project_status(id: &str, data: &Value, job: &Value, storage: &Value) -> Result<Status> {
    let state = data["printer"]["state"]
        .as_str()
        .ok_or(Error::Protocol("Printer status has no state"))?;
    let state = match state {
        "IDLE" | "BUSY" | "PRINTING" | "PAUSED" | "FINISHED" | "STOPPED" | "ERROR"
        | "ATTENTION" | "READY" => state,
        _ => "UNKNOWN",
    }
    .to_owned();
    let storages = storage["storage_list"].as_array().ok_or(Error::Protocol(
        "Printer storage response has no storage list",
    ))?;
    let usb = storages.iter().find(|s| {
        s["path"]
            .as_str()
            .is_some_and(|p| p.trim_end_matches('/').eq_ignore_ascii_case("/usb"))
    });
    let printer = &data["printer"];
    // Discard a job sampled across a job-id change instead of showing another
    // file's geometry/thumbnail against the current progress.
    let current_id = data["job"]["id"].as_u64();
    let empty = Value::Null;
    let job = if current_id.is_some() && current_id != job["id"].as_u64() {
        &empty
    } else {
        job
    };
    let file = &job["file"];
    let job_number = |key: &str| number(&data["job"][key]).or_else(|| number(&job[key]));
    let job_seconds = |key: &str| data["job"][key].as_u64().or_else(|| job[key].as_u64());
    let filename = file["display_name"]
        .as_str()
        .or_else(|| file["name"].as_str())
        .filter(|v| v.len() <= 256 && !v.chars().any(char::is_control))
        .map(str::to_owned);
    Ok(Status {
        printer: id.into(),
        state,
        nozzle_c: number(&printer["temp_nozzle"]),
        nozzle_target_c: number(&printer["target_nozzle"]),
        bed_c: number(&printer["temp_bed"]),
        bed_target_c: number(&printer["target_bed"]),
        progress_percent: job_number("progress"),
        time_printing_s: job_seconds("time_printing"),
        time_remaining_s: job_seconds("time_remaining"),
        job_id: current_id.or_else(|| job["id"].as_u64()),
        job_file: filename,
        thumbnail_ref: thumbnail_path(&file["refs"]["thumbnail"]),
        axis_z_mm: precise_number(&printer["axis_z"]),
        total_height_mm: precise_number(&file["meta"]["max_layer_z"]),
        layer_height_mm: precise_number(&file["meta"]["layer_height"]),
        fan_hotend_rpm: printer["fan_hotend"].as_u64(),
        fan_print_rpm: printer["fan_print"].as_u64(),
        speed_percent: number(&printer["speed"]),
        flow_percent: number(&printer["flow"]),
        storage_available: usb.and_then(|s| s["available"].as_bool()).unwrap_or(false),
        storage_read_only: usb.and_then(|s| s["read_only"].as_bool()).unwrap_or(false),
        free_bytes: usb.and_then(|s| s["free_space"].as_u64()),
    })
}
fn thumbnail_path(value: &Value) -> Option<String> {
    let raw = value.as_str()?;
    if raw.len() > 2048
        || !raw.starts_with('/')
        || raw.starts_with("//")
        || raw.contains(['?', '#', '\\'])
        || raw.chars().any(char::is_control)
    {
        return None;
    }
    let url = Url::parse(&format!("http://printer.invalid{raw}")).ok()?;
    let path = url.path();
    // Normalize before checking the prefix: encoded dot segments cannot escape
    // into another API; credentials never go to a printer-supplied origin.
    if !(path.starts_with("/thumb/l/") || path.starts_with("/api/thumbnails/")) {
        return None;
    }
    Some(path.to_owned())
}
fn precise_number(value: &Value) -> Option<f64> {
    value.as_f64().filter(|n| n.is_finite())
}
fn number(value: &Value) -> Option<f64> {
    precise_number(value).map(|n| (n * 10.0).round() / 10.0)
}
fn ready(state: &str) -> Result<()> {
    if matches!(state, "IDLE" | "READY" | "FINISHED") {
        Ok(())
    } else {
        Err(Error::Invalid(
            "Print start requires an IDLE, READY or FINISHED printer",
        ))
    }
}
pub fn file_path(file: &str) -> Result<String> {
    let file = file.strip_prefix("/usb/").unwrap_or(file);
    let lower = file.to_ascii_lowercase();
    if !(lower.ends_with(".gcode") || lower.ends_with(".bgcode"))
        || file.contains('\\')
        || file.chars().any(char::is_control)
        || file
            .split('/')
            .any(|s| s.is_empty() || s == "." || s == "..")
    {
        return Err(Error::Invalid(
            "Use a USB-relative .bgcode or .gcode file path without traversal",
        ));
    }
    // Encode each UTF-8 segment with RFC3986's unreserved set. In particular,
    // '+' must be %2B because PrusaLink decodes a literal '+' as a space.
    let mut path = String::from("/api/v1/files/usb");
    for segment in file.split('/') {
        path.push('/');
        for byte in segment.bytes() {
            if byte.is_ascii_alphanumeric() || matches!(byte, b'-' | b'.' | b'_' | b'~') {
                path.push(char::from(byte));
            } else {
                path.push_str(&format!("%{byte:02X}"));
            }
        }
    }
    Ok(path)
}

#[derive(Serialize)]
pub struct Discovered {
    pub host: String,
    pub hostname: String,
}
pub fn probe(host: &str) -> Result<Option<Discovered>> {
    let host = normalize_host(host)?;
    let result = agent(Duration::from_secs(4))
        .get(format!("{host}/api/version"))
        .call()
        .map_err(|error| transport(error, false))?;
    let identity = match result.status().as_u16() {
        401 => result
            .headers()
            .get_all("WWW-Authenticate")
            .iter()
            .filter_map(|header| header.to_str().ok())
            .any(|header| Challenge::parse(header).is_ok_and(|c| c.realm == "Printer API")),
        200 => json(result)?["text"] == "PrusaLink",
        _ => false,
    };
    let hostname = Url::parse(&host)
        .ok()
        .and_then(|u| u.host_str().map(str::to_owned))
        .ok_or(Error::Invalid("Invalid printer host"))?;
    Ok(identity.then_some(Discovered { host, hostname }))
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[test]
    fn snapshots_project_optional_fields_without_crossing_job_boundaries() {
        let data = json!({"printer":{"state":"PRINTING","temp_nozzle":214.94,"target_nozzle":215,"temp_bed":59.5,"target_bed":60,"axis_z":15,"fan_hotend":4200,"fan_print":3000,"flow":95,"speed":100},"job":{"id":42,"progress":25,"time_printing":100,"time_remaining":300}});
        let job = json!({"id":42,"file":{"display_name":"Part.bgcode","refs":{"thumbnail":"/thumb/l/usb/part.bgcode"},"meta":{"max_layer_z":30,"layer_height":0.15}}});
        let storage = json!({"storage_list":[{"path":"/usb/","available":true,"read_only":false,"free_space":1234}]});
        let snapshot = project_status("printer1", &data, &job, &storage).unwrap();
        assert_eq!(snapshot.nozzle_c, Some(214.9));
        assert_eq!(snapshot.time_remaining_s, Some(300));
        assert_eq!(snapshot.job_file.as_deref(), Some("Part.bgcode"));
        assert_eq!(snapshot.total_height_mm, Some(30.0));
        assert_eq!(snapshot.axis_z_mm, Some(15.0));
        assert_eq!(snapshot.layer_height_mm, Some(0.15));
        assert_eq!(snapshot.fan_hotend_rpm, Some(4200));
        assert!(snapshot.storage_available);
        let mut different = job;
        different["id"] = json!(43);
        let raced = project_status("printer1", &data, &different, &storage).unwrap();
        assert_eq!(raced.job_id, Some(42));
        assert!(
            raced.job_file.is_none()
                && raced.thumbnail_ref.is_none()
                && raced.total_height_mm.is_none()
        );
        let idle = project_status(
            "printer1",
            &json!({"printer":{"state":"IDLE"}}),
            &Value::Null,
            &json!({"storage_list":[]}),
        )
        .unwrap();
        assert!(idle.progress_percent.is_none() && !idle.storage_available);
        assert!(project_status("printer1", &json!({}), &Value::Null, &storage).is_err());
    }

    #[test]
    fn file_and_thumbnail_paths_cannot_escape_their_owned_routes() {
        assert_eq!(
            file_path("/usb/folder/part one.bgcode").unwrap(),
            "/api/v1/files/usb/folder/part%20one.bgcode"
        );
        assert_eq!(
            file_path("%2e%2e.gcode").unwrap(),
            "/api/v1/files/usb/%252e%252e.gcode"
        );
        for invalid in [
            "../part.gcode",
            "/etc/part.gcode",
            "a//part.bgcode",
            "a\\part.gcode",
            "part.txt",
            "a\n.gcode",
        ] {
            assert!(file_path(invalid).is_err(), "{invalid}");
        }
        for invalid in [
            "https://remote.invalid/thumb/l/a",
            "//remote.invalid/thumb/l/a",
            "/thumb/l/../../api/v1/info",
            "/thumb/l/%2e%2e/%2e%2e/api/v1/info",
            "/thumb/l/a?x=y",
            "/thumb/l/a#fragment",
            "/api/v1/info",
        ] {
            assert!(thumbnail_path(&json!(invalid)).is_none(), "{invalid}");
        }
        assert_eq!(
            thumbnail_path(&json!("/thumb/l/usb/part.bgcode")).as_deref(),
            Some("/thumb/l/usb/part.bgcode")
        );
        for state in ["PRINTING", "PAUSED", "BUSY", "ERROR", "UNKNOWN"] {
            assert!(ready(state).is_err());
        }
        for state in ["IDLE", "READY", "FINISHED"] {
            assert!(ready(state).is_ok());
        }
    }
}
