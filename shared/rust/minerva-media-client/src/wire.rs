/// Binary frame decoder state machine.
///
/// Wire format per spec appendix (all little-endian):
///   [0]     = frame type  (0=NEW_MESSAGE, 1=FILE_INFO, 2=FILE_DATA, 3=FILE_END)
///   [1..17] = message_id  (16-byte UUID, opaque)
///   [17..]  = payload (type-dependent)
///
/// NEW_MESSAGE payload:
///   u32 json_len | u32 num_files | JSON bytes
///
/// FILE_INFO payload:
///   u64 file_size | u32 name_len | filename (utf-8)
///   file_index assigned sequentially as FILE_INFO frames arrive.
///
/// FILE_DATA payload:
///   raw chunk bytes; appended to the "current" (last FILE_INFO'd) file buffer.
///   May arrive before the corresponding FILE_INFO — buffered and flushed when
///   FILE_INFO for that slot arrives.
///
/// FILE_END payload:
///   u32 file_index; that file's buffer is complete.

use crate::MediaError;

pub const FRAME_NEW_MESSAGE: u8 = 0;
pub const FRAME_FILE_INFO: u8 = 1;
pub const FRAME_FILE_DATA: u8 = 2;
pub const FRAME_FILE_END: u8 = 3;

const HEADER_LEN: usize = 17; // 1 type + 16 message_id

/// The JSON header extracted from a NEW_MESSAGE frame.
#[derive(Debug)]
pub struct MessageHeader {
    pub request_id: String,
    pub num_files: u32,
    pub raw: serde_json::Value,
}

/// A file entry being assembled.
#[derive(Debug, Default)]
pub struct FileEntry {
    pub filename: String,
    pub expected_size: u64,
    pub data: Vec<u8>,
    pub complete: bool,
}

/// Output from `decode_frame`.
#[derive(Debug)]
pub enum FrameEvent {
    /// A new message header arrived.
    NewMessage { message_id: [u8; 16], header: MessageHeader },
    /// FILE_INFO for file_index.
    FileInfo { message_id: [u8; 16], file_index: u32, filename: String, file_size: u64 },
    /// FILE_DATA chunk for the current message's "active" file slot.
    FileData { message_id: [u8; 16], chunk: Vec<u8> },
    /// FILE_END — file at file_index is complete.
    FileEnd { message_id: [u8; 16], file_index: u32 },
}

/// Decode a single binary WebSocket frame into a `FrameEvent`.
pub fn decode_frame(data: &[u8]) -> Result<FrameEvent, MediaError> {
    if data.len() < HEADER_LEN {
        return Err(MediaError::Protocol(format!(
            "frame too short: {} bytes",
            data.len()
        )));
    }

    let frame_type = data[0];
    let mut message_id = [0u8; 16];
    message_id.copy_from_slice(&data[1..17]);
    let payload = &data[HEADER_LEN..];

    match frame_type {
        FRAME_NEW_MESSAGE => {
            if payload.len() < 8 {
                return Err(MediaError::Protocol(
                    "NEW_MESSAGE payload too short".into(),
                ));
            }
            let json_len = u32::from_le_bytes(payload[0..4].try_into().unwrap()) as usize;
            let num_files = u32::from_le_bytes(payload[4..8].try_into().unwrap());
            if payload.len() < 8 + json_len {
                return Err(MediaError::Protocol(format!(
                    "NEW_MESSAGE: expected {} JSON bytes, got {}",
                    json_len,
                    payload.len() - 8
                )));
            }
            let json_bytes = &payload[8..8 + json_len];
            let raw: serde_json::Value = serde_json::from_slice(json_bytes)
                .map_err(|e| MediaError::Protocol(format!("NEW_MESSAGE JSON parse: {e}")))?;

            // Extract params.request_id
            let request_id = raw
                .get("params")
                .and_then(|p| p.get("request_id"))
                .and_then(|v| v.as_str())
                .unwrap_or("")
                .to_owned();

            Ok(FrameEvent::NewMessage {
                message_id,
                header: MessageHeader {
                    request_id,
                    num_files,
                    raw,
                },
            })
        }

        FRAME_FILE_INFO => {
            if payload.len() < 12 {
                return Err(MediaError::Protocol(
                    "FILE_INFO payload too short".into(),
                ));
            }
            let file_size = u64::from_le_bytes(payload[0..8].try_into().unwrap());
            let name_len = u32::from_le_bytes(payload[8..12].try_into().unwrap()) as usize;
            if payload.len() < 12 + name_len {
                return Err(MediaError::Protocol(format!(
                    "FILE_INFO: expected {} name bytes, got {}",
                    name_len,
                    payload.len() - 12
                )));
            }
            let filename = String::from_utf8(payload[12..12 + name_len].to_vec())
                .map_err(|e| MediaError::Protocol(format!("FILE_INFO filename utf8: {e}")))?;
            // file_index is assigned by the caller's state machine
            Ok(FrameEvent::FileInfo {
                message_id,
                file_index: 0, // caller overwrites
                filename,
                file_size,
            })
        }

        FRAME_FILE_DATA => Ok(FrameEvent::FileData {
            message_id,
            chunk: payload.to_vec(),
        }),

        FRAME_FILE_END => {
            if payload.len() < 4 {
                return Err(MediaError::Protocol(
                    "FILE_END payload too short".into(),
                ));
            }
            let file_index = u32::from_le_bytes(payload[0..4].try_into().unwrap());
            Ok(FrameEvent::FileEnd {
                message_id,
                file_index,
            })
        }

        t => Err(MediaError::Protocol(format!("unknown frame type {t}"))),
    }
}

/// Per-request binary frame assembler.
///
/// Handles:
/// - Multi-chunk FILE_DATA reassembly.
/// - Out-of-order FILE_DATA (arrives before FILE_INFO): buffered until FILE_INFO.
/// - Sequential file_index assignment on FILE_INFO arrival.
#[derive(Debug, Default)]
pub struct MessageAssembler {
    /// Files indexed by their sequential position (order of FILE_INFO arrival).
    pub files: Vec<FileEntry>,
    /// Buffered FILE_DATA chunks keyed by file_index (for pre-arrival data).
    pub pending_data: std::collections::HashMap<u32, Vec<Vec<u8>>>,
    /// The next file_index to assign to the next FILE_INFO.
    pub next_file_index: u32,
    /// Tracks completed file count.
    pub completed_files: u32,
}

impl MessageAssembler {
    pub fn new() -> Self {
        Self::default()
    }

    /// Process a FILE_INFO event; returns the assigned file_index.
    pub fn on_file_info(&mut self, filename: String, file_size: u64) -> u32 {
        let idx = self.next_file_index;
        self.next_file_index += 1;

        let mut entry = FileEntry {
            filename,
            expected_size: file_size,
            data: Vec::new(),
            complete: false,
        };

        // Flush any pre-arrived chunks.
        if let Some(chunks) = self.pending_data.remove(&idx) {
            for chunk in chunks {
                entry.data.extend_from_slice(&chunk);
            }
        }

        self.files.push(entry);
        idx
    }

    /// Process a FILE_DATA chunk. `active_file_index` is the index of the file
    /// that owns this data (the caller tracks which FILE_INFO was most recent).
    pub fn on_file_data(&mut self, active_file_index: u32, chunk: Vec<u8>) {
        if let Some(entry) = self.files.get_mut(active_file_index as usize) {
            entry.data.extend_from_slice(&chunk);
        } else {
            // Pre-arrival buffering.
            self.pending_data
                .entry(active_file_index)
                .or_default()
                .push(chunk);
        }
    }

    /// Mark file at `file_index` as complete; returns true when all files done.
    pub fn on_file_end(&mut self, file_index: u32) {
        if let Some(entry) = self.files.get_mut(file_index as usize) {
            entry.complete = true;
            self.completed_files += 1;
        }
    }

    pub fn all_complete(&self, num_files: u32) -> bool {
        self.completed_files >= num_files
    }
}
