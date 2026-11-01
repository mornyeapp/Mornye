use super::*;
use std::cell::RefCell;
use std::f64::consts::TAU;
use std::sync::atomic::{AtomicBool, Ordering};

fn ok() -> Result<(), String> {
    Ok(())
}

fn english_match() -> Value {
    json!({
        "matches": [{"id": "1", "offset": 60.0}],
        "track": {
            "key": "644597356",
            "title": "Kill Bill",
            "subtitle": "SZA",
            "isrc": "usrc12204584",
            "url": "https://www.shazam.com/track/644597356/kill-bill",
            "genres": {"primary": "R&B/Soul"},
            "images": {
                "coverart": "https://example.com/400.jpg",
                "coverarthq": "https://example.com/hq.jpg",
            },
            "sections": [
                {"type": "SONG", "metadata": [
                    {"title": "Album", "text": "SOS"},
                    {"title": "Label", "text": "Top Dawg Entertainment/RCA Records"},
                    {"title": "Released", "text": "2022"},
                ]},
                {"type": "LYRICS", "text": ["never read"]},
            ],
        },
    })
}

fn song(value: &Value) -> RecognizedSong {
    match parse_response(200, value.to_string().as_bytes()) {
        Ok(RecognitionOutcome::Match(song)) => *song,
        other => panic!("expected a match, got {other:?}"),
    }
}

#[test]
fn locale_falls_back_to_english_united_states() {
    assert_eq!(
        RecognitionLocale::new("DE", "de"),
        RecognitionLocale {
            language: "de".into(),
            country: "DE".into()
        }
    );
    assert_eq!(RecognitionLocale::new("fil", "PH").language, "fil");
    for (language, country) in [
        ("", "US"),
        ("en", ""),
        ("e1", "US"),
        ("en", "USA"),
        ("zh-Hans", "CN"),
    ] {
        assert_eq!(
            RecognitionLocale::new(language, country),
            RecognitionLocale::new("en", "US"),
            "{language}_{country}"
        );
    }
    assert_eq!(
        RecognitionLocale::new("pt", "BR").content_language(),
        "pt-BR"
    );
}

#[test]
fn timezone_must_look_like_a_zone_name() {
    assert_eq!(normalize_timezone(" Asia/Jakarta\n"), "Asia/Jakarta");
    assert_eq!(normalize_timezone("Etc/GMT-7"), "Etc/GMT-7");
    assert_eq!(
        normalize_timezone("America/Port-au-Prince"),
        "America/Port-au-Prince"
    );
    for invalid in [
        "",
        "../etc",
        "+07:00",
        "Asia/Jakarta;x",
        "Europe/Paris\u{e9}",
    ] {
        assert_eq!(normalize_timezone(invalid), "UTC", "{invalid:?}");
    }
}

#[test]
fn request_uses_locale_ids_and_no_location() {
    let locale = RecognitionLocale::new("fr", "FR");
    assert_eq!(
        request_url(&locale, "A", "B"),
        "https://amp.shazam.com/discovery/v5/fr/FR/android/-/tag/A/B?sync=true&webv3=true&sampling=true&connected=&shazamapiversion=v3&sharehub=true&video=v3"
    );
    let mut signature = Signature {
        sample_count: 64_000,
        ..Signature::default()
    };
    signature.bands[1].push(mornye_core::music_signature::Peak {
        pass: 1,
        magnitude: 2,
        corrected_bin: 3,
    });
    let body: Value = serde_json::from_str(&request_body(&signature, "Europe/Paris", 42)).unwrap();
    assert_eq!(
        body,
        json!({
            "signature": {"samplems": 4000, "timestamp": 42, "uri": signature.data_uri()},
            "timestamp": 42,
            "timezone": "Europe/Paris",
        })
    );
    assert_eq!(
        request_headers(&locale),
        BTreeMap::from([
            ("Content-Type".into(), "application/json".into()),
            ("Content-Language".into(), "fr-FR".into()),
        ])
    );
}

#[test]
fn ids_are_random_version_four_uuids() {
    let (first, second) = (uuid(), uuid());
    assert_ne!(first, second);
    assert_eq!(first.len(), 36);
    assert_eq!(&first[14..15], "4");
    assert!("89AB".contains(&first[19..20]));
    assert!(
        first
            .bytes()
            .all(|b| b == b'-' || b.is_ascii_digit() || b.is_ascii_uppercase())
    );
}

#[test]
fn a_match_reads_the_song_and_its_details() {
    assert_eq!(
        song(&english_match()),
        RecognizedSong {
            key: "644597356".into(),
            title: "Kill Bill".into(),
            artist: "SZA".into(),
            album: Some("SOS".into()),
            cover_url: Some("https://example.com/hq.jpg".into()),
            release: Some("2022".into()),
            genre: Some("R&B/Soul".into()),
            label: Some("Top Dawg Entertainment/RCA Records".into()),
            isrc: Some("USRC12204584".into()),
            web_url: Some("https://www.shazam.com/track/644597356/kill-bill".into()),
        }
    );
}

#[test]
fn localized_details_fall_back_to_their_order() {
    let mut german = english_match();
    german["track"]["sections"][0]["metadata"][2]["title"] = json!("Veröffentlicht:");
    let found = song(&german);
    assert_eq!(found.album.as_deref(), Some("SOS"));
    assert_eq!(found.release.as_deref(), Some("2022"));

    let mut unknown = english_match();
    unknown["track"]["sections"][0]["metadata"] = json!([
        {"title": "アルバム", "text": "1989"},
        {"title": "レーベル", "text": "Big Machine"},
        {"title": "リリース", "text": "2014-10-27"},
    ]);
    let found = song(&unknown);
    assert_eq!(found.album.as_deref(), Some("1989"));
    assert_eq!(found.label.as_deref(), Some("Big Machine"));
    assert_eq!(found.release.as_deref(), Some("2014-10-27"));

    // Without a clear order nothing is guessed.
    unknown["track"]["sections"][0]["metadata"] = json!([{"title": "X", "text": "Somewhere"}]);
    let found = song(&unknown);
    assert_eq!(
        (found.album, found.label, found.release),
        (None, None, None)
    );
}

#[test]
fn optional_fields_fall_back_and_reject_non_web_links() {
    let mut value = english_match();
    let track = value["track"].as_object_mut().unwrap();
    track.remove("isrc");
    track.remove("sections");
    track["images"] = json!({"coverart": "https://example.com/400.jpg", "coverarthq": ""});
    track["url"] = json!("javascript:alert(1)");
    track.insert(
        "share".into(),
        json!({"href": "https://www.shazam.com/track/1"}),
    );
    track.insert("releasedate".into(), json!("21-12-2022"));
    let found = song(&value);
    assert_eq!(
        found.cover_url.as_deref(),
        Some("https://example.com/400.jpg")
    );
    assert_eq!(
        found.web_url.as_deref(),
        Some("https://www.shazam.com/track/1")
    );
    assert_eq!(found.release.as_deref(), Some("21-12-2022"));
    assert_eq!((found.isrc, found.album), (None, None));
}

#[test]
fn statuses_and_bodies_map_to_outcomes() {
    let no_match = Ok(RecognitionOutcome::NoMatch);
    assert_eq!(parse_response(404, b""), no_match);
    assert_eq!(
        parse_response(200, br#"{"matches": [], "tagid": "x"}"#),
        no_match
    );
    assert_eq!(
        parse_response(
            200,
            br#"{"matches": [], "track": {"title": "", "subtitle": "A"}}"#
        ),
        no_match
    );
    assert_eq!(parse_response(429, b""), Err(RecognitionError::RateLimited));
    assert_eq!(
        parse_response(503, b"busy"),
        Err(RecognitionError::Unavailable("status 503".into()))
    );
    assert_eq!(
        parse_response(400, b"{}"),
        Err(RecognitionError::Unavailable("status 400".into()))
    );
    assert_eq!(
        parse_response(200, b"<html>"),
        Err(RecognitionError::Unavailable("invalid response".into()))
    );
    assert_eq!(RecognitionError::RateLimited.kind(), "rate_limited");
    assert_eq!(RecognitionError::Network(String::new()).kind(), "network");
}

type ScriptedReply = Result<(u16, Vec<u8>), String>;

/// Answers each POST from a script and records what was sent.
struct Scripted {
    replies: RefCell<Vec<ScriptedReply>>,
    urls: RefCell<Vec<String>>,
}

impl Scripted {
    fn new(replies: Vec<ScriptedReply>) -> Self {
        Self {
            replies: RefCell::new(replies.into_iter().rev().collect()),
            urls: RefCell::default(),
        }
    }
}

impl Transport for Scripted {
    fn post(
        &self,
        url: &str,
        headers: BTreeMap<String, String>,
        _body: String,
        _check: &Check<'_>,
    ) -> Result<(u16, Vec<u8>), String> {
        assert_eq!(headers["Content-Language"], "en-US");
        self.urls.borrow_mut().push(url.into());
        self.replies.borrow_mut().pop().expect("unexpected request")
    }
}

fn run(replies: Vec<ScriptedReply>) -> (Result<RecognitionOutcome, RecognitionError>, usize) {
    let transport = Scripted::new(replies);
    let mut recognizer = Recognizer::new(&transport);
    recognizer.policy = RetryPolicy {
        rate_limit_delay: Duration::from_millis(1),
        retry_delay: Duration::from_millis(1),
        quick_failure: Duration::from_secs(5),
    };
    let result = recognizer.recognize(
        &Signature::default(),
        &RecognitionLocale::new("xx-invalid", ""),
        "UTC",
        &ok,
    );
    let urls = transport.urls.borrow();
    // Each attempt is a fresh request.
    if urls.len() == 2 {
        assert_ne!(urls[0], urls[1]);
    }
    (result, urls.len())
}

#[test]
fn rate_limits_server_errors_and_quick_failures_retry_once() {
    let matched = english_match().to_string().into_bytes();
    let found = Ok(RecognitionOutcome::Match(Box::new(song(&english_match()))));
    assert_eq!(
        run(vec![Ok((429, vec![])), Ok((200, matched.clone()))]),
        (found.clone(), 2)
    );
    assert_eq!(
        run(vec![Ok((502, vec![])), Ok((200, matched.clone()))]),
        (found.clone(), 2)
    );
    assert_eq!(
        run(vec![Err("reset".into()), Ok((200, matched))]),
        (found, 2)
    );
    assert_eq!(
        run(vec![Ok((429, vec![])), Ok((429, vec![]))]),
        (Err(RecognitionError::RateLimited), 2)
    );
    assert_eq!(
        run(vec![Ok((500, vec![])), Ok((503, vec![]))]),
        (Err(RecognitionError::Unavailable("status 503".into())), 2)
    );
    assert_eq!(
        run(vec![Err("reset".into()), Err("refused".into())]),
        (Err(RecognitionError::Network("refused".into())), 2)
    );
}

#[test]
fn answers_and_client_errors_do_not_retry() {
    assert_eq!(
        run(vec![Ok((404, vec![]))]),
        (Ok(RecognitionOutcome::NoMatch), 1)
    );
    assert_eq!(
        run(vec![Ok((403, vec![]))]),
        (Err(RecognitionError::Unavailable("status 403".into())), 1)
    );
    assert_eq!(
        run(vec![Ok((200, b"oops".to_vec()))]),
        (
            Err(RecognitionError::Unavailable("invalid response".into())),
            1
        )
    );
}

#[test]
fn slow_network_failures_are_not_repeated() {
    let transport = Scripted::new(vec![Err("timed out".into())]);
    let mut recognizer = Recognizer::new(&transport);
    recognizer.policy.quick_failure = Duration::ZERO;
    let result = recognizer.recognize(
        &Signature::default(),
        &RecognitionLocale::new("en", "US"),
        "UTC",
        &ok,
    );
    assert_eq!(result, Err(RecognitionError::Network("timed out".into())));
}

#[test]
fn cancelling_during_the_backoff_stops_without_another_request() {
    let transport = Scripted::new(vec![Ok((429, vec![]))]);
    let cancelled = AtomicBool::new(false);
    let check = || {
        if cancelled.load(Ordering::SeqCst) {
            Err("cancelled".to_owned())
        } else {
            Ok(())
        }
    };
    struct CancelAfter<'a>(&'a Scripted, &'a AtomicBool);
    impl Transport for CancelAfter<'_> {
        fn post(
            &self,
            url: &str,
            headers: BTreeMap<String, String>,
            body: String,
            check: &Check<'_>,
        ) -> Result<(u16, Vec<u8>), String> {
            let reply = self.0.post(url, headers, body, check);
            self.1.store(true, Ordering::SeqCst);
            reply
        }
    }
    let wrapper = CancelAfter(&transport, &cancelled);
    let recognizer = Recognizer::new(&wrapper);
    let result = recognizer.recognize(
        &Signature::default(),
        &RecognitionLocale::new("en", "US"),
        "UTC",
        &check,
    );
    assert_eq!(result, Err(RecognitionError::Cancelled("cancelled".into())));
    assert_eq!(transport.urls.borrow().len(), 1);
}

#[test]
fn short_and_quiet_audio_is_not_sent() {
    let rate = SIGNATURE_SAMPLE_RATE;
    assert_eq!(prepare(&vec![8_000; 2 * rate], &ok), Ok(Prepared::TooShort));
    assert_eq!(prepare(&vec![0; 4 * rate], &ok), Ok(Prepared::Quiet));
    // A faint hum is under the level floor.
    let hum = (0..4 * rate)
        .map(|index| ((TAU * 100.0 * index as f64 / rate as f64).sin() * 20.0) as i16)
        .collect::<Vec<_>>();
    assert_eq!(prepare(&hum, &ok), Ok(Prepared::Quiet));
    // Loud but steady: plenty of level, nothing to fingerprint.
    let steady = (0..4 * rate)
        .map(|index| ((TAU * 1000.0 * index as f64 / rate as f64).sin() * 12_000.0) as i16)
        .collect::<Vec<_>>();
    assert_eq!(prepare(&steady, &ok), Ok(Prepared::Quiet));

    let mut seed = 7_u32;
    let music = (0..4 * rate)
        .map(|index| {
            seed = seed.wrapping_mul(1_664_525).wrapping_add(1_013_904_223);
            let beat = if index % (rate / 4) < rate / 16 {
                1.0
            } else {
                0.1
            };
            let tone = (TAU * (400.0 + (index / (rate / 4)) as f64 * 150.0) * index as f64
                / rate as f64)
                .sin();
            ((tone * beat * 0.6 + (f64::from(seed >> 16) / 65536.0 - 0.5) * 0.1) * 20_000.0) as i16
        })
        .collect::<Vec<_>>();
    match prepare(&music, &ok) {
        Ok(Prepared::Ready(signature)) => assert!(signature.peak_count() >= MIN_PEAKS),
        other => panic!("expected a signature, got {other:?}"),
    }
}
