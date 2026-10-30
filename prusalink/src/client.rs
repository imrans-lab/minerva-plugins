//! Prusa's published v1 API, with fresh per-tool vault credentials and no redirects.
use std::fs::File;
use std::io::Read;
use std::path::Path;
use std::time::Duration;

use base64::Engine;
use serde::Serialize;
use serde_json::Value;
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
    ureq::AgentBuilder::new()
        .redirects(0)
        .try_proxy_from_env(false)
        // No recycled connection means ureq cannot replay a stale-connection
        // DELETE/PUT. Hardware mutations are never automatically retried.
        .max_idle_connections(0)
        .timeout_connect(Duration::from_secs(3))
        .timeout_read(Duration::from_secs(5))
        .timeout_write(Duration::from_secs(15))
        .timeout(timeout)
        .build()
}
fn transport(error: ureq::Transport, mutation: bool) -> Error {
    // Preserve the connection stage without exposing raw transport diagnostics.
    Error::Transport {
        mutation,
        connection: matches!(
            error.kind(),
            ureq::ErrorKind::ConnectionFailed | ureq::ErrorKind::Dns
        ),
    }
}
fn response(
    result: std::result::Result<ureq::Response, ureq::Error>,
    mutation: bool,
) -> Result<ureq::Response> {
    match result {
        Ok(response) => Ok(response),
        Err(ureq::Error::Status(status, _)) => Err(Error::Http(status)),
        Err(ureq::Error::Transport(error)) => Err(transport(error, mutation)),
    }
}
fn json(response: ureq::Response) -> Result<Value> {
    let mut bytes = Vec::new();
    response
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
            nonce_count: 0,
            cnonce: nonce.iter().map(|b| format!("{b:02x}")).collect(),
        })
    }
    fn authenticate(&mut self) -> Result<()> {
        if self.challenge.is_some() {
            return Ok(());
        }
        for path in ["/api/version", "/api/v1/status"] {
            match self
                .agent
                .get(&format!("{}{path}", self.printer.host))
                .call()
            {
                Err(ureq::Error::Status(401, response)) => {
                    for header in response.all("WWW-Authenticate") {
                        if let Ok(challenge) = Challenge::parse(header) {
                            if challenge.realm != "Printer API" {
                                continue;
                            }
                            self.challenge = Some(challenge);
                            return Ok(());
                        }
                    }
                    return Err(Error::Protocol(
                        "Printer requires unsupported Digest authentication",
                    ));
                }
                Ok(response) if response.status() == 200 => continue,
                Err(ureq::Error::Status(status, _)) => return Err(Error::Http(status)),
                Err(ureq::Error::Transport(error)) => return Err(transport(error, false)),
                _ => {
                    return Err(Error::Transport {
                        mutation: false,
                        connection: false,
                    })
                }
            }
        }
        Err(Error::Protocol(
            "Printer did not provide a PrusaLink Digest challenge",
        ))
    }
    fn request(&mut self, method: &str, path: &str) -> Result<ureq::Request> {
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
        Ok(self
            .agent
            .request(method, &format!("{}{path}", self.printer.host))
            .set("Authorization", &authorization)
            .set("Accept", "application/json"))
    }
    fn get(&mut self, path: &str) -> Result<Value> {
        let response = response(self.request("GET", path)?.call(), false)?;
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
        let response = match response(self.request("GET", &path)?.call(), false) {
            Err(Error::Http(404)) => return Ok(serde_json::json!({"available":false})),
            other => other?,
        };
        let mut bytes = Vec::new();
        response
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
            .set("Content-Type", "application/octet-stream")
            .set("Content-Length", &metadata.len().to_string())
            .set("Print-After-Upload", if start { "?1" } else { "?0" })
            .set("Overwrite", "?0");
        let result = response(request.send(file), true)?;
        if result.status() != 201 {
            return Err(Error::Protocol(
                "Printer did not confirm the upload; inspect its file list before retrying",
            ));
        }
        Ok(
            serde_json::json!({"printer":self.printer.id(),"file":name,"uploaded":true,"start_requested":start,"overwrite":false}),
        )
    }
    pub fn print(&mut self, file: &str) -> Result<Value> {
        let path = file_path(file)?;
        ready(&self.status()?.state)?;
        let result = response(self.request("POST", &path)?.call(), true)?;
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
        let result = response(
            self.request("DELETE", &format!("/api/v1/job/{id}"))?.call(),
            true,
        )?;
        if result.status() != 204 {
            return Err(Error::Protocol(
                "Printer did not confirm stop; check the printer before retrying",
            ));
        }
        Ok(serde_json::json!({"printer":self.printer.id(),"job_id":id,"stop_requested":true}))
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
    let mut url = Url::parse("http://printer.invalid/api/v1/files/usb/")
        .map_err(|_| Error::Protocol("Internal printer path is invalid"))?;
    {
        let mut segments = url
            .path_segments_mut()
            .map_err(|_| Error::Protocol("Internal printer path is invalid"))?;
        segments.pop_if_empty();
        for segment in file.split('/') {
            segments.push(segment);
        }
    }
    Ok(url.path().into())
}

#[derive(Serialize)]
pub struct Discovered {
    pub host: String,
    pub hostname: String,
}
pub fn probe(host: &str) -> Result<Option<Discovered>> {
    let host = normalize_host(host)?;
    let identity = match agent(Duration::from_secs(4))
        .get(&format!("{host}/api/version"))
        .call()
    {
        Err(ureq::Error::Status(401, response)) => response
            .all("WWW-Authenticate")
            .into_iter()
            .any(|h| Challenge::parse(h).is_ok_and(|c| c.realm == "Printer API")),
        Ok(response) if response.status() == 200 => json(response)?["text"] == "PrusaLink",
        Err(ureq::Error::Transport(error)) => return Err(transport(error, false)),
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
