//! Song recognition for the microphone screen. Flutter sends the audio
//! captured so far as 16 kHz mono s16le and gets back a match, no match, or
//! the kind of failure; only a fingerprint leaves the device.
use mornye_network::NetworkService;
use mornye_providers::recognition::{
    NetworkTransport, Prepared, RecognitionError, RecognitionLocale, RecognitionOutcome,
    Recognizer, prepare,
};
use serde_json::{Value, json};
use std::sync::{Arc, OnceLock};

/// More than the screen ever captures, with room for a late chunk.
const MAX_BYTES: usize = 16_000 * 2 * 20;

pub(crate) fn execute(
    request: &Value,
    bytes: &[u8],
    check: &(dyn Fn() -> Result<(), String> + Sync),
) -> Result<Value, String> {
    if !bytes.len().is_multiple_of(2) || bytes.len() > MAX_BYTES {
        return Err("Recognition audio must be at most 20 s of 16-bit PCM".into());
    }
    let samples: Vec<i16> = bytes
        .as_chunks::<2>()
        .0
        .iter()
        .map(|pair| i16::from_le_bytes(*pair))
        .collect();
    let signature = match prepare(&samples, check)? {
        Prepared::Ready(signature) => signature,
        Prepared::TooShort => return Ok(json!({"status": "too_short"})),
        Prepared::Quiet => return Ok(json!({"status": "quiet"})),
    };
    let field = |name: &str| {
        request
            .get(name)
            .and_then(Value::as_str)
            .unwrap_or_default()
    };
    let locale = RecognitionLocale::new(field("language"), field("country"));
    let transport = NetworkTransport::new(network()?);
    match Recognizer::new(&transport).recognize(&signature, &locale, field("timezone"), check) {
        Ok(RecognitionOutcome::Match(song)) => Ok(json!({"status": "match", "song": song})),
        Ok(RecognitionOutcome::NoMatch) => Ok(json!({"status": "no_match"})),
        Err(RecognitionError::Cancelled(message)) => Err(message),
        Err(error) => Ok(json!({"status": error.kind()})),
    }
}

fn network() -> Result<&'static Arc<NetworkService>, String> {
    static NETWORK: OnceLock<Result<Arc<NetworkService>, String>> = OnceLock::new();
    NETWORK
        .get_or_init(|| NetworkService::new().map_err(|error| error.to_string()))
        .as_ref()
        .map_err(Clone::clone)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn run(bytes: &[u8]) -> Result<Value, String> {
        execute(&json!({"operation": "recognize_song"}), bytes, &|| Ok(()))
    }

    #[test]
    fn audio_that_cannot_match_is_answered_without_a_request() {
        assert_eq!(
            run(&[0; 16_000 * 2]).unwrap(),
            json!({"status": "too_short"})
        );
        assert_eq!(
            run(&[0; 16_000 * 2 * 5]).unwrap(),
            json!({"status": "quiet"})
        );
        assert!(run(&[0; 3]).is_err());
        assert!(run(&vec![0; MAX_BYTES + 2]).is_err());
        let cancelled = execute(
            &json!({}),
            &[1; 16_000 * 2 * 4],
            &|| Err("cancelled".into()),
        );
        assert_eq!(cancelled, Err("cancelled".into()));
    }
}
