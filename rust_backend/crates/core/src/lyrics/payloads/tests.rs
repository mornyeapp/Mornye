use super::*;

#[test]
fn zarz_lrc_apple_preserves_syllables_and_separate_background_groups() {
    let raw = serde_json::json!({
        "type": "Syllable",
        "elrcMultiPerson": "[00:01.00]Lead\n[00:02.00]Echo",
        "content": [{
            "timestamp": 1009, "endtime": 4000, "agent": "v3", "oppositeTurn": true,
            "text": [
                {"text": "To", "part": true, "timestamp": 1009, "endtime": 1500},
                {"text": "gether", "timestamp": 1500, "endtime": 4000}
            ],
            "backgroundLines": [
                {"timestamp": 2000, "endtime": 2500, "text": [
                    {"text": "Echo", "timestamp": 2000, "endtime": 2500}
                ]},
                {"timestamp": 3000, "endtime": 3500, "text": [
                    {"text": "Again", "timestamp": 3000, "endtime": 3500}
                ]}
            ]
        }]
    })
    .to_string();
    for words in [false, true] {
        let text = format_zarz_lrc_apple(&raw, true, words).unwrap();
        assert!(text.starts_with("[00:01.009]v1:"));
        assert_eq!(text.matches("[bg:").count(), 2);
        let lyrics = LyricsResponse::from_text(&text, "Zarz-LRC", "Zarz-LRC");
        assert_eq!(lyrics.lines().len(), 1);
        assert_eq!(lyrics.lines()[0].start_time_ms, 1009);
        if words {
            assert!(text.contains("To<00:01.50><00:01.50>gether"));
        } else {
            assert!(text.contains("Together"));
        }
        let solo = format_zarz_lrc_apple(&raw, false, words).unwrap();
        assert!(!solo.contains("[bg:"));
        assert!(!solo.contains("v1:"));
    }
}

#[test]
fn zarz_lrc_apple_handles_line_only_unsynced_and_invalid_responses() {
    let mut raw = serde_json::json!({
        "type": "Line", "content": [{
            "timestamp": 1500, "text": [{"text": "Whole"}, {"text": "line"}]
        }]
    });
    assert_eq!(
        format_zarz_lrc_apple(&raw.to_string(), false, true).unwrap(),
        "[00:01.50]Whole line"
    );
    raw["type"] = "Unsynced".into();
    raw["content"][0]["timestamp"] = serde_json::Value::Null;
    let text = format_zarz_lrc_apple(&raw.to_string(), true, true).unwrap();
    assert_eq!(text, "Whole line");
    assert_eq!(
        LyricsResponse::from_text(&text, "Example", "Example").sync_type,
        "UNSYNCED"
    );
    for raw in [
        "<html>Error</html>",
        r#"{"error":{"code":"APPLE_AUTH_REQUIRED"}}"#,
        "{}",
    ] {
        assert!(format_zarz_lrc_apple(raw, true, true).is_err());
    }
}

#[test]
fn apple_agents_restore_vocal_sides_without_reformatting_word_times() {
    let mut raw = serde_json::json!({
        "type": "Syllable",
        "elrcMultiPerson": "[00:01.01]v1: <00:01.009>Lead<00:02.00>\n[bg:<00:01.50>Echo<00:02.50>]\n[00:03.00]v2: <00:03.00>Guest<00:04.00>\n[00:05.00]v2: <00:05.00>Together<00:06.00>\n[00:07.00]v2: Third",
        "content": [
            {"timestamp": 1009, "agent": "lead"},
            {"timestamp": 3000, "agent": "guest"},
            {"timestamp": 5000, "agent": "all"},
            {"timestamp": 7000, "agent": "third"}
        ],
        "metadata": {"agents": [
            {"id": "lead", "type": "person"},
            {"id": "guest", "type": "person"},
            {"id": "all", "type": "group"},
            {"id": "third", "type": "person"}
        ]}
    });
    let text = format_apple(&raw.to_string(), true, true).unwrap();
    assert_eq!(
        text,
        "[00:01.01]v1: <00:01.009>Lead<00:02.00>\n[bg:<00:01.50>Echo<00:02.50>]\n[00:03.00]v2: <00:03.00>Guest<00:04.00>\n[00:05.00]v1: <00:05.00>Together<00:06.00>\n[00:07.00]v3: Third"
    );
    let lyrics = LyricsResponse::from_text(&text, "Apple Music", "Apple Music");
    let stored = lrc::with_metadata(&lyrics, "Track", "Artist");
    assert!(stored.contains("[00:05.00]v1: <00:05.00>Together<00:06.00>"));
    assert!(stored.contains("[bg:<00:01.50>Echo<00:02.50>]"));

    // Some responses carry vocal labels only in the regular eLRC field.
    // It must use the same agent correction as the multi-person field.
    raw["elrc"] = raw
        .as_object_mut()
        .unwrap()
        .remove("elrcMultiPerson")
        .unwrap();
    assert_eq!(format_apple(&raw.to_string(), true, true).unwrap(), text);
    assert_eq!(
        format_apple(&raw.to_string(), false, true).unwrap(),
        raw["elrc"].as_str().unwrap()
    );
}

#[test]
fn apple_v3_does_not_depend_on_agent_order_or_group_metadata() {
    for agents in [
        serde_json::Value::Null,
        serde_json::json!([
            {"id": "v1", "type": "person"},
            {"id": "v3", "type": "person"},
            {"id": "v2", "type": "person"}
        ]),
    ] {
        let raw = serde_json::json!({
            "type": "Syllable",
            "elrcMultiPerson": "[00:01.00]v2:Together\n[00:02.00]v1:Guest",
            "content": [{"timestamp": 1000, "agent": "v3"}, {"timestamp": 2000, "agent": "v2"}],
            "metadata": {"agents": agents}
        });
        assert_eq!(
            format_apple(&raw.to_string(), true, true).unwrap(),
            "[00:01.00]v1:Together\n[00:02.00]v2:Guest"
        );
    }
}

#[test]
fn apple_content_fallback_honors_agents_only_when_multi_person_is_enabled() {
    let raw = serde_json::json!({
        "type": "Syllable",
        "content": [{"timestamp": 1000, "oppositeTurn": true, "agent": "group", "text": [
            {"text": "Together", "timestamp": 1000, "endtime": 2000}
        ]}],
        "metadata": {"agents": [{"id": "group", "type": "group"}]}
    })
    .to_string();
    for timing in [false, true] {
        assert!(
            format_apple(&raw, true, timing)
                .unwrap()
                .starts_with("[00:01.00]v1:")
        );
        assert!(!format_apple(&raw, false, timing).unwrap().contains("v1:"));
        assert!(!format_apple(&raw, false, timing).unwrap().contains("v2:"));
    }
}

#[test]
fn apple_voice_correction_preserves_unknown_or_ambiguous_lines() {
    let text = "[00:01.00]v2: Unknown\n[00:02.00]v2: Too far\n[00:03.00]v2: Ambiguous\n[00:04.00]v2: Exact";
    let mut raw = serde_json::json!({"elrcMultiPerson": text});
    assert_eq!(format_apple(&raw.to_string(), true, true).unwrap(), text);
    raw["metadata"] = serde_json::json!({"agents": [
        {"id": "v1", "type": "person"}, {"id": "v2", "type": "person"},
        {"id": "v3", "type": "group"}
    ]});
    raw["content"] = serde_json::json!([
        {"timestamp": 1000, "agent": "unknown"},
        {"timestamp": 2011, "agent": "v3"},
        {"timestamp": 3000, "agent": "v3"},
        {"timestamp": 3000, "agent": "v2"},
        {"timestamp": 3999, "agent": "v2"},
        {"timestamp": 4000, "agent": "v3"}
    ]);
    assert_eq!(
        format_apple(&raw.to_string(), true, true).unwrap(),
        text.replace("[00:04.00]v2:", "[00:04.00]v1:")
    );
}

fn payload(lang: &str) -> serde_json::Value {
    serde_json::json!({
        "type": "Syllable",
        "elrc": "[00:01.010]<00:01.009>Original <00:01.307>\n[00:02.000]Next",
        "content": [{"timestamp": 1009, "text": [
            {"text": "Original", "timestamp": 1009, "endtime": 1307}
        ]}, {"timestamp": 2001, "text": [{"text": "Next"}]}],
        "metadata": {
            "language": lang,
            "transliterations": [{"lang": format!("{lang}-Latn"), "lines": [
                {"timestamp": 1009, "text": "Romanized"},
                {"timestamp": 2001, "text": "Next romanized"}
            ]}],
            "translations": [{"lang": "en-US", "lines": [
                {"timestamp": 1009, "text": "English"},
                {"timestamp": 2001, "text": "Next English"}
            ]}]
        }
    })
}

#[test]
fn supplements_follow_output_timestamps_in_both_apple_modes() {
    for lang in ["ja", "ko", "zh-Hans"] {
        for word_timing in [false, true] {
            let raw = payload(lang).to_string();
            let text = format_apple(&raw, false, word_timing).unwrap();
            let mut lyrics = LyricsResponse::from_text(&text, "Apple Music", "Apple Music");
            apple_supplements(&raw, &mut lyrics);
            assert_eq!(lyrics.lines()[0].romanization.as_deref(), Some("Romanized"));
            assert_eq!(
                lyrics.lines()[1].translation.as_deref(),
                Some("Next English")
            );
            let start = if word_timing { 1010 } else { 1009 };
            assert_eq!(lyrics.lines()[0].start_time_ms, start);
            let exported = lrc::with_metadata(&lyrics, "Track", "Artist");
            assert!(exported.contains(&format!("[x-romanized:{start}:Romanized]")));
            assert!(exported.contains(&lrc::timestamp(start)));
            if word_timing {
                assert!(exported.contains("<00:01.307>"));
            }
            // Persistence uses this same JSON response contract.
            let restored: LyricsResponse =
                serde_json::from_str(&serde_json::to_string(&lyrics).unwrap()).unwrap();
            assert_eq!(restored, lyrics);
        }
    }
}

#[test]
fn nearest_matching_is_bounded_and_exact_matches_win() {
    let mut raw = payload("ja");
    raw["metadata"]["transliterations"][0]["lines"] = serde_json::json!([
        {"timestamp": 1009, "text": "Rounded"},
        {"timestamp": 1010, "text": "Exact"},
        {"timestamp": 1001, "text": "Less accurate"},
        {"timestamp": 2011, "text": "Too far"},
        {"timestamp": 2990, "text": "Boundary"},
        {"timestamp": 4005, "text": "Tie"}
    ]);
    let mut lyrics = LyricsResponse::from_text(
        "[00:01.010]A\n[00:02.00]B\n[00:03.00]C\n[00:04.00]D\n[00:04.010]E",
        "",
        "",
    );
    apple_supplements(&raw.to_string(), &mut lyrics);
    let actual: Vec<_> = lyrics
        .lines()
        .iter()
        .map(|line| line.romanization.as_deref())
        .collect();
    assert_eq!(
        actual,
        [Some("Exact"), None, Some("Boundary"), Some("Tie"), None]
    );
}

#[test]
fn malformed_optional_lines_do_not_hide_other_supplements() {
    let mut raw = payload("ja");
    raw["metadata"]["transliterations"][0]["lines"] = serde_json::json!([
        null, {"text": "Missing time"}, {"timestamp": "1009", "text": "Bad time"},
        {"timestamp": 1009, "text": []}, {"timestamp": -1, "text": "Negative"},
        {"timestamp": 2001, "text": "  Next romanized  "}
    ]);
    let mut lyrics = LyricsResponse::from_text("[00:01.01]A\n[00:02.00]B", "", "");
    apple_supplements(&raw.to_string(), &mut lyrics);
    assert!(lyrics.lines()[0].romanization.is_none());
    assert_eq!(lyrics.lines()[0].translation.as_deref(), Some("English"));
    assert_eq!(
        lyrics.lines()[1].romanization.as_deref(),
        Some("Next romanized")
    );
}

#[test]
fn language_selection_prefers_song_language_and_usable_groups() {
    let mut raw = payload("ja");
    raw["metadata"]["transliterations"] = serde_json::json!([
        {"lang": "ja-Latn", "lines": []},
        {"lang": "ko-Latn", "lines": [{"timestamp": 1009, "text": "Other language"}]},
        {"lang": "ja-Kana", "lines": [{"timestamp": 1009, "text": "Not Latin"}]},
        {"lang": "ja-Latn", "lines": [{"timestamp": 1009, "text": "Romanized"}]}
    ]);
    raw["metadata"]["translations"] = serde_json::json!([
        {"lang": "en", "lines": null},
        {"lang": "fr", "lines": [{"timestamp": 1009, "text": "French"}]},
        {"lang": "en-GB", "lines": [{"timestamp": 1009, "text": "English"}]}
    ]);
    let mut lyrics = LyricsResponse::from_text("[00:01.01]Original", "", "");
    apple_supplements(&raw.to_string(), &mut lyrics);
    assert_eq!(lyrics.lines()[0].romanization.as_deref(), Some("Romanized"));
    assert_eq!(lyrics.lines()[0].translation.as_deref(), Some("English"));
}

#[test]
fn absent_or_invalid_metadata_preserves_original_lyrics() {
    for raw in [
        "{}",
        "not json",
        r#"{"metadata":null}"#,
        r#"{"metadata":{"translations":5}}"#,
    ] {
        let mut lyrics = LyricsResponse::from_text("[00:01.00]Original", "", "");
        let original = lyrics.clone();
        apple_supplements(raw, &mut lyrics);
        assert_eq!(lyrics, original);
    }
    let mut plain = LyricsResponse::from_text("Original", "", "");
    apple_supplements(&payload("ja").to_string(), &mut plain);
    assert!(plain.lines()[0].romanization.is_none());
}

#[test]
fn romanization_spans_keep_syllables_spaces_and_original_word_times() {
    let mut raw = payload("ja");
    raw["metadata"]["transliterations"][0]["lines"][0] = serde_json::json!({
        "timestamp": 1009, "text": "Roma nized", "spans": [
            {"text": "Ro", "begin": 1009, "end": 1107},
            {"text": "ma", "begin": 1107, "end": 1307},
            {"text": "nized", "begin": 2003, "end": 2497}
        ]
    });
    let mut lyrics = LyricsResponse::from_text("[00:01.010]Original", "", "");
    apple_supplements(&raw.to_string(), &mut lyrics);
    let words = lyrics.lines()[0].romanization_words.as_ref().unwrap();
    assert_eq!(
        words
            .iter()
            .map(|word| word.text.as_str())
            .collect::<Vec<_>>(),
        ["Ro", "ma ", "nized"]
    );
    assert_eq!(words[0].start_time_ms, 1009);
    assert_eq!(words[1].end_time_ms, 1307);
    assert_eq!(words[2].start_time_ms, 2003);
    assert_eq!(words[2].end_time_ms, 2497);

    let output = lrc::with_metadata(&lyrics, "Track", "Artist");
    let written = output
        .lines()
        .find_map(|line| {
            line.strip_prefix("[x-romanized-words:1010:")
                .and_then(|line| line.strip_suffix(']'))
        })
        .unwrap();
    assert_eq!(
        written,
        "<00:01.009>Ro<00:01.107>ma <00:01.307><00:02.003>nized<00:02.497>"
    );
}

#[test]
fn invalid_romanization_timing_falls_back_to_readable_text() {
    for spans in [
        serde_json::json!([{"text": "Other", "begin": 1009, "end": 1307}]),
        serde_json::json!([{"text": "Romanized", "begin": 1009, "end": 900}]),
        serde_json::json!([{"text": "Romanized", "begin": 1009}]),
        serde_json::json!([{"text": "Ro", "begin": 1009, "end": 1307}]),
    ] {
        let mut raw = payload("ja");
        raw["metadata"]["transliterations"][0]["lines"][0]["spans"] = spans;
        let mut lyrics = LyricsResponse::from_text("[00:01.010]Original", "", "");
        apple_supplements(&raw.to_string(), &mut lyrics);
        assert_eq!(lyrics.lines()[0].romanization.as_deref(), Some("Romanized"));
        assert!(lyrics.lines()[0].romanization_words.is_none());
    }
}
