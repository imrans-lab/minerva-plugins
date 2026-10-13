//! Binary audio frames: the 4-byte header from protocol.md ("Audio frames")
//! and the per-connection mic stream bookkeeping.

use std::fmt;

pub const HEADER_LEN: usize = 4;
pub const MAX_PAYLOAD: usize = 4096;

const KIND_MASK: u8 = 0x0F;
const RESERVED_MASK: u8 = 0x70;
const EOS_BIT: u8 = 0x80;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Kind {
    /// Device→plugin.
    Mic,
    /// Plugin→device.
    Speaker,
}

impl Kind {
    fn code(self) -> u8 {
        match self {
            Self::Mic => 1,
            Self::Speaker => 2,
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct FrameHeader {
    pub kind: Kind,
    pub eos: bool,
    pub stream: u8,
    pub seq: u16,
}

impl FrameHeader {
    pub fn encode(&self) -> [u8; HEADER_LEN] {
        let seq = self.seq.to_le_bytes();
        let eos = if self.eos { EOS_BIT } else { 0 };
        [self.kind.code() | eos, self.stream, seq[0], seq[1]]
    }
}

/// Each variant is a protocol violation (close 4002).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum FrameError {
    ShortHeader(usize),
    ReservedBits,
    UnknownKind(u8),
    OddPayload(usize),
    PayloadTooLarge(usize),
}

impl fmt::Display for FrameError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::ShortHeader(n) => write!(f, "binary frame of {n} bytes has no 4-byte header"),
            Self::ReservedBits => f.write_str("audio header reserved bits set"),
            Self::UnknownKind(k) => write!(f, "unknown audio kind {k}"),
            Self::OddPayload(n) => write!(f, "audio payload of {n} bytes is odd"),
            Self::PayloadTooLarge(n) => write!(f, "audio payload of {n} bytes is over 4096"),
        }
    }
}

impl std::error::Error for FrameError {}

pub fn parse_frame(frame: &[u8]) -> Result<(FrameHeader, &[u8]), FrameError> {
    let (header, payload) = frame
        .split_first_chunk::<HEADER_LEN>()
        .ok_or(FrameError::ShortHeader(frame.len()))?;
    if header[0] & RESERVED_MASK != 0 {
        return Err(FrameError::ReservedBits);
    }
    let kind = match header[0] & KIND_MASK {
        1 => Kind::Mic,
        2 => Kind::Speaker,
        other => return Err(FrameError::UnknownKind(other)),
    };
    if payload.len() % 2 != 0 {
        return Err(FrameError::OddPayload(payload.len()));
    }
    if payload.len() > MAX_PAYLOAD {
        return Err(FrameError::PayloadTooLarge(payload.len()));
    }
    let header = FrameHeader {
        kind,
        eos: header[0] & EOS_BIT != 0,
        stream: header[1],
        seq: u16::from_le_bytes([header[2], header[3]]),
    };
    Ok((header, payload))
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum MicFrame {
    /// In sequence on the current stream. `eos` ends the stream.
    Accepted { eos: bool },
    /// Out of sequence on the current stream: report `audio_gap`; the stream
    /// continues from this frame.
    Gap { expected: u16, got: u16 },
    /// Not the current mic stream: drop without a reply.
    NotCurrent,
}

/// The mic stream the device announced with `ptt_down`, and the sequence
/// number its next frame must carry.
#[derive(Debug, Default)]
pub struct MicStream {
    current: Option<(u8, u16)>,
}

impl MicStream {
    pub fn announce(&mut self, stream: u8) {
        self.current = Some((stream, 0));
    }

    /// `ptt_up` arriving before the EOS frame counts as EOS (protocol.md,
    /// push-to-talk step 3).
    pub fn end(&mut self, stream: u8) {
        if matches!(self.current, Some((s, _)) if s == stream) {
            self.current = None;
        }
    }

    pub fn current(&self) -> Option<u8> {
        self.current.map(|(s, _)| s)
    }

    pub fn on_frame(&mut self, header: &FrameHeader) -> MicFrame {
        let Some((stream, expected)) = self.current else {
            return MicFrame::NotCurrent;
        };
        if header.kind != Kind::Mic || header.stream != stream {
            return MicFrame::NotCurrent;
        }
        self.current = if header.eos {
            None
        } else {
            Some((stream, header.seq.wrapping_add(1)))
        };
        if header.seq == expected {
            MicFrame::Accepted { eos: header.eos }
        } else {
            MicFrame::Gap {
                expected,
                got: header.seq,
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn frame(header: [u8; 4], payload: usize) -> Vec<u8> {
        let mut f = header.to_vec();
        f.resize(HEADER_LEN + payload, 0);
        f
    }

    #[test]
    fn parses_example_headers() {
        let bytes = frame([0x81, 0x07, 0x02, 0x00], 1280);
        let (h, p) = parse_frame(&bytes).unwrap();
        assert_eq!(
            h,
            FrameHeader {
                kind: Kind::Mic,
                eos: true,
                stream: 7,
                seq: 2
            }
        );
        assert_eq!(p.len(), 1280);
        let (h, _) = parse_frame(&frame([0x02, 0x03, 0x34, 0x12], 0)).unwrap();
        assert_eq!((h.kind, h.eos, h.seq), (Kind::Speaker, false, 0x1234));
    }

    #[test]
    fn encode_round_trips() {
        for header in [
            FrameHeader {
                kind: Kind::Mic,
                eos: false,
                stream: 255,
                seq: 65535,
            },
            FrameHeader {
                kind: Kind::Speaker,
                eos: true,
                stream: 0,
                seq: 1,
            },
        ] {
            let bytes = header.encode();
            assert_eq!(parse_frame(&bytes).unwrap().0, header);
        }
    }

    #[test]
    fn rejects_every_malformed_shape() {
        assert_eq!(parse_frame(&[1, 2, 3]), Err(FrameError::ShortHeader(3)));
        for reserved in [0x10, 0x20, 0x40] {
            assert_eq!(
                parse_frame(&frame([0x01 | reserved, 1, 0, 0], 0)),
                Err(FrameError::ReservedBits)
            );
        }
        assert_eq!(
            parse_frame(&frame([0x00, 1, 0, 0], 0)),
            Err(FrameError::UnknownKind(0))
        );
        assert_eq!(
            parse_frame(&frame([0x03, 1, 0, 0], 0)),
            Err(FrameError::UnknownKind(3))
        );
        assert_eq!(
            parse_frame(&frame([0x01, 1, 0, 0], 641)),
            Err(FrameError::OddPayload(641))
        );
        assert_eq!(
            parse_frame(&frame([0x01, 1, 0, 0], 4098)),
            Err(FrameError::PayloadTooLarge(4098))
        );
        assert!(parse_frame(&frame([0x01, 1, 0, 0], 4096)).is_ok());
    }

    fn mic(stream: u8, seq: u16, eos: bool) -> FrameHeader {
        FrameHeader {
            kind: Kind::Mic,
            eos,
            stream,
            seq,
        }
    }

    #[test]
    fn mic_stream_tracks_sequence_gaps_and_eos() {
        let mut m = MicStream::default();
        assert_eq!(m.on_frame(&mic(1, 0, false)), MicFrame::NotCurrent);
        m.announce(1);
        assert_eq!(m.on_frame(&mic(2, 0, false)), MicFrame::NotCurrent);
        assert_eq!(
            m.on_frame(&mic(1, 0, false)),
            MicFrame::Accepted { eos: false }
        );
        assert_eq!(
            m.on_frame(&mic(1, 2, false)),
            MicFrame::Gap {
                expected: 1,
                got: 2
            }
        );
        assert_eq!(
            m.on_frame(&mic(1, 3, true)),
            MicFrame::Accepted { eos: true }
        );
        assert_eq!(m.current(), None);
        assert_eq!(m.on_frame(&mic(1, 4, false)), MicFrame::NotCurrent);
    }

    #[test]
    fn sequence_wraps_and_ptt_up_ends_the_stream() {
        let mut m = MicStream::default();
        m.announce(9);
        m.current = Some((9, 65535));
        assert_eq!(
            m.on_frame(&mic(9, 65535, false)),
            MicFrame::Accepted { eos: false }
        );
        assert_eq!(
            m.on_frame(&mic(9, 0, false)),
            MicFrame::Accepted { eos: false }
        );
        m.end(8);
        assert_eq!(m.current(), Some(9));
        m.end(9);
        assert_eq!(m.current(), None);
    }
}
