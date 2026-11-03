//! The Cast v2 channel framing: each message is a 4-byte big-endian length
//! followed by a protobuf `CastMessage`. Only the six fields every sender
//! uses are written; unknown fields are skipped when reading.
//!
//! ```text
//! message CastMessage {
//!   required ProtocolVersion protocol_version = 1;  // CASTV2_1_0 = 0
//!   required string source_id = 2;
//!   required string destination_id = 3;
//!   required string namespace = 4;
//!   required PayloadType payload_type = 5;          // STRING = 0
//!   optional string payload_utf8 = 6;
//!   optional bytes payload_binary = 7;
//! }
//! ```

use std::io;

/// Receivers reject frames above 64 KiB.
pub(crate) const MAX_FRAME: usize = 64 * 1024;

pub(crate) const CONNECTION: &str = "urn:x-cast:com.google.cast.tp.connection";
pub(crate) const HEARTBEAT: &str = "urn:x-cast:com.google.cast.tp.heartbeat";
pub(crate) const RECEIVER: &str = "urn:x-cast:com.google.cast.receiver";
pub(crate) const MEDIA: &str = "urn:x-cast:com.google.cast.media";

#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) struct Message {
    pub(crate) source: String,
    pub(crate) destination: String,
    pub(crate) namespace: String,
    /// Empty for binary payloads, which no namespace used here sends.
    pub(crate) payload: String,
}

impl Message {
    pub(crate) fn new(source: &str, destination: &str, namespace: &str, payload: String) -> Self {
        Self {
            source: source.into(),
            destination: destination.into(),
            namespace: namespace.into(),
            payload,
        }
    }

    /// The length-prefixed frame.
    pub(crate) fn encode(&self) -> Vec<u8> {
        let mut body = Vec::with_capacity(64 + self.payload.len());
        body.extend_from_slice(&[0x08, 0x00]);
        field(&mut body, 2, self.source.as_bytes());
        field(&mut body, 3, self.destination.as_bytes());
        field(&mut body, 4, self.namespace.as_bytes());
        body.extend_from_slice(&[0x28, 0x00]);
        field(&mut body, 6, self.payload.as_bytes());
        let mut frame = Vec::with_capacity(4 + body.len());
        frame.extend_from_slice(&(body.len() as u32).to_be_bytes());
        frame.extend_from_slice(&body);
        frame
    }

    /// Parses one frame body (without its length prefix).
    pub(crate) fn decode(mut bytes: &[u8]) -> io::Result<Self> {
        let invalid = || io::Error::new(io::ErrorKind::InvalidData, "malformed Cast message");
        let mut message = Self::new("", "", "", String::new());
        while !bytes.is_empty() {
            let key = varint(&mut bytes).ok_or_else(invalid)?;
            match key & 7 {
                0 => {
                    varint(&mut bytes).ok_or_else(invalid)?;
                }
                2 => {
                    let len = varint(&mut bytes).ok_or_else(invalid)? as usize;
                    let value = bytes.get(..len).ok_or_else(invalid)?;
                    bytes = &bytes[len..];
                    let text = || String::from_utf8(value.to_vec()).map_err(|_| invalid());
                    match key >> 3 {
                        2 => message.source = text()?,
                        3 => message.destination = text()?,
                        4 => message.namespace = text()?,
                        6 => message.payload = text()?,
                        _ => {}
                    }
                }
                5 => bytes = bytes.get(4..).ok_or_else(invalid)?,
                1 => bytes = bytes.get(8..).ok_or_else(invalid)?,
                _ => return Err(invalid()),
            }
        }
        Ok(message)
    }
}

fn field(out: &mut Vec<u8>, number: u64, value: &[u8]) {
    put_varint(out, number << 3 | 2);
    put_varint(out, value.len() as u64);
    out.extend_from_slice(value);
}

fn put_varint(out: &mut Vec<u8>, mut value: u64) {
    while value >= 0x80 {
        out.push((value as u8) | 0x80);
        value >>= 7;
    }
    out.push(value as u8);
}

fn varint(bytes: &mut &[u8]) -> Option<u64> {
    let mut value = 0u64;
    for shift in (0..64).step_by(7) {
        let (&byte, rest) = bytes.split_first()?;
        *bytes = rest;
        value |= u64::from(byte & 0x7f) << shift;
        if byte < 0x80 {
            return Some(value);
        }
    }
    None
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn frames_round_trip_and_match_the_reference_encoding() {
        let message = Message::new(
            "sender-0",
            "receiver-0",
            HEARTBEAT,
            r#"{"type":"PING"}"#.into(),
        );
        let frame = message.encode();
        let len = u32::from_be_bytes(frame[..4].try_into().unwrap()) as usize;
        assert_eq!(len, frame.len() - 4);
        // protocol_version, then source_id as field 2.
        assert_eq!(&frame[4..8], &[0x08, 0x00, 0x12, 8]);
        assert_eq!(Message::decode(&frame[4..]).unwrap(), message);
    }

    #[test]
    fn long_payloads_use_multi_byte_lengths() {
        let payload = "x".repeat(300);
        let message = Message::new("a", "b", MEDIA, payload);
        let frame = message.encode();
        assert_eq!(Message::decode(&frame[4..]).unwrap(), message);
    }

    #[test]
    fn unknown_fields_are_skipped_and_truncation_fails() {
        let mut body = Message::new("a", "b", RECEIVER, "{}".into()).encode()[4..].to_vec();
        // payload_binary (field 7) and a fixed32 field 9.
        body.extend_from_slice(&[0x3a, 0x01, 0xff, 0x4d, 1, 2, 3, 4]);
        assert_eq!(Message::decode(&body).unwrap().payload, "{}");
        assert!(Message::decode(&body[..body.len() - 2]).is_err());
    }
}
