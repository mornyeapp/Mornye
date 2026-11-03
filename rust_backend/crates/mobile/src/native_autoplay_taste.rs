//! Deterministic session skip-gram training, leaving persistence to Flutter.
use serde::Deserialize;
use serde_json::{Value, json};
use std::collections::HashMap;

const DIMENSIONS: usize = 16;
const WINDOW: usize = 3;
const VOCABULARY: usize = 3000;
const RATE: f64 = 0.025;

/// Matches the pinned Dart VM's seeded multiply-with-carry generator.
pub(crate) struct DartRandom(u64);

impl DartRandom {
    pub(crate) fn new(mut seed: u64) -> Self {
        seed = (!seed).wrapping_add(seed << 21);
        seed ^= seed >> 24;
        seed = seed.wrapping_mul(265);
        seed ^= seed >> 14;
        seed = seed.wrapping_mul(21);
        seed ^= seed >> 28;
        seed = seed.wrapping_add(seed << 31);
        let mut random = Self(if seed == 0 { 0x5a17 } else { seed });
        for _ in 0..4 {
            random.next_state();
        }
        random
    }

    fn next_state(&mut self) {
        self.0 = 0xffffda61_u64.wrapping_mul(self.0 & 0xffffffff) + (self.0 >> 32);
    }

    pub(crate) fn next_int(&mut self, max: u64) -> u64 {
        assert!(max > 0 && max <= 1 << 32);
        loop {
            self.next_state();
            let random = self.0 & 0xffffffff;
            if max.is_power_of_two() {
                return random & (max - 1);
            }
            let result = random % max;
            if random - result + max <= 1 << 32 {
                return result;
            }
        }
    }

    pub(crate) fn next_double(&mut self) -> f64 {
        (self.next_int(1 << 26) as f64 * (1_u64 << 27) as f64 + self.next_int(1 << 27) as f64)
            / (1_u64 << 53) as f64
    }
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct Play {
    id: i64,
    song: String,
    artist: String,
    at_micros: i64,
    kind: Kind,
    reward: f64,
}

#[derive(Deserialize)]
#[serde(rename_all = "lowercase")]
enum Kind {
    Listened,
    Replayed,
    Loved,
    Playlisted,
    Skipped,
}

struct Position<'a> {
    song: &'a str,
    artist: &'a str,
    weight: f64,
}

struct Slot {
    song: i32,
    artist: i32,
    weight: f64,
}

struct Skip {
    song: i32,
    at: usize,
    weight: f64,
}

struct Session {
    plays: Vec<Slot>,
    skips: Vec<Skip>,
}

pub(crate) fn execute(
    request: &Value,
    check: &dyn Fn() -> Result<(), String>,
) -> Result<Value, String> {
    check()?;
    let plays: Vec<Play> = serde_json::from_value(request["plays"].clone())
        .map_err(|error| format!("Invalid autoplay taste history: {error}"))?;
    if plays.len() > 5000 || plays.iter().any(|play| !play.reward.is_finite()) {
        return Err("Invalid autoplay taste history bounds".into());
    }
    let mut sessions = Vec::<Vec<Position<'_>>>::new();
    let mut endorsed = HashMap::<&str, f64>::new();
    let mut latest: Option<i64> = None;
    let mut positives = 0;
    let mut through = 0;
    for play in &plays {
        check()?;
        if latest.is_none_or(|latest| play.at_micros as i128 - latest as i128 > 1_800_000_000) {
            finish_session(sessions.last_mut(), &endorsed);
            endorsed.clear();
            sessions.push(Vec::new());
            latest = Some(play.at_micros);
        }
        latest = Some(latest.unwrap().max(play.at_micros));
        through = through.max(play.id);
        let strength = match play.kind {
            Kind::Listened => play.reward,
            Kind::Replayed | Kind::Playlisted => 1.5,
            Kind::Loved => 2.0,
            Kind::Skipped => -(1.0 - 2.0 * play.reward).clamp(0.0, 1.0),
        };
        if matches!(play.kind, Kind::Loved | Kind::Playlisted) {
            let value = endorsed.entry(&play.song).or_default();
            *value = value.max(strength);
            continue;
        }
        if strength > 0.0 {
            positives += 1;
        }
        if strength == 0.0 {
            continue;
        }
        let positions = sessions.last_mut().unwrap();
        if let Some(last) = positions.last_mut()
            && last.song == play.song
        {
            last.weight = last.weight.max(strength);
        } else {
            positions.push(Position {
                song: &play.song,
                artist: &play.artist,
                weight: strength,
            });
        }
    }
    finish_session(sessions.last_mut(), &endorsed);
    let mut counts = HashMap::<String, usize>::new();
    for session in &sessions {
        check()?;
        for position in session {
            if position.weight <= 0.0 {
                continue;
            }
            *counts.entry(format!("song:{}", position.song)).or_default() += 1;
            if !position.artist.is_empty() {
                *counts
                    .entry(format!("artist:{}", position.artist))
                    .or_default() += 1;
            }
        }
    }
    let mut tokens: Vec<_> = counts
        .iter()
        .filter(|(_, count)| **count >= 2)
        .map(|(token, _)| token.clone())
        .collect();
    tokens.sort_by(|a, b| {
        counts[b]
            .cmp(&counts[a])
            .then_with(|| a.encode_utf16().cmp(b.encode_utf16()))
    });
    tokens.truncate(VOCABULARY);
    let ids: HashMap<_, _> = tokens
        .iter()
        .enumerate()
        .map(|(id, token)| (token.as_str(), id as i32))
        .collect();
    let mut encoded = Vec::new();
    let mut slots = 0;
    for session in sessions {
        check()?;
        let mut kept = Vec::new();
        let mut skips = Vec::new();
        for position in session {
            let song = *ids
                .get(format!("song:{}", position.song).as_str())
                .unwrap_or(&-1);
            if position.weight < 0.0 {
                if song >= 0 {
                    skips.push(Skip {
                        song,
                        at: kept.len(),
                        weight: -position.weight,
                    });
                }
                continue;
            }
            let artist = if position.artist.is_empty() {
                -1
            } else {
                *ids.get(format!("artist:{}", position.artist).as_str())
                    .unwrap_or(&-1)
            };
            if song >= 0 || artist >= 0 {
                kept.push(Slot {
                    song,
                    artist,
                    weight: position.weight,
                });
            }
        }
        if kept.len() > 1 || (kept.len() == 1 && !skips.is_empty()) {
            slots += kept.len();
            encoded.push(Session { plays: kept, skips });
        }
    }
    let mut random = DartRandom::new(0x7a57e);
    let input = (0..tokens.len() * DIMENSIONS)
        .map(|_| (random.next_double() - 0.5) / DIMENSIONS as f64)
        .collect();
    let mut total = 0.0;
    let cumulative = tokens
        .iter()
        .map(|token| {
            total += (counts[token] as f64).powf(0.75);
            total
        })
        .collect();
    let mut model = Trainer {
        input,
        output: vec![0.0; tokens.len() * DIMENSIONS],
        error: [0.0; DIMENSIONS],
        random,
        cumulative,
        total,
    };
    let epochs = if slots == 0 {
        0
    } else {
        40000_usize.div_ceil(slots).clamp(5, 40)
    };
    let steps = (epochs * slots).max(1);
    let mut step = 0;
    for _ in 0..epochs {
        check()?;
        for session in &encoded {
            check()?;
            let kept = &session.plays;
            let mut alpha = RATE;
            for (i, here) in kept.iter().enumerate() {
                if i % 32 == 0 {
                    check()?;
                }
                alpha = RATE * (1.0 - step as f64 / steps as f64).max(0.0001);
                step += 1;
                model.together(here.song, here.artist, alpha * here.weight);
                model.together(here.artist, here.song, alpha * here.weight);
                for (j, there) in kept
                    .iter()
                    .enumerate()
                    .take((i + WINDOW + 1).min(kept.len()))
                    .skip(i.saturating_sub(WINDOW))
                {
                    if j == i {
                        continue;
                    }
                    let rate = alpha
                        * (here.weight * there.weight).sqrt()
                        * (WINDOW + 1 - i.abs_diff(j)) as f64
                        / WINDOW as f64;
                    model.together(here.song, there.song, rate);
                    model.together(here.song, there.artist, rate);
                    model.together(here.artist, there.song, rate);
                    model.together(here.artist, there.artist, rate);
                }
            }
            for skip in &session.skips {
                for (j, there) in kept
                    .iter()
                    .enumerate()
                    .take(kept.len().min(skip.at + WINDOW))
                    .skip(skip.at.saturating_sub(WINDOW))
                {
                    let distance = if j < skip.at {
                        skip.at - j
                    } else {
                        j - skip.at + 1
                    };
                    let rate = alpha
                        * 0.5
                        * skip.weight
                        * there.weight.sqrt()
                        * (WINDOW + 1 - distance) as f64
                        / WINDOW as f64;
                    model.apart(skip.song, there.song, rate);
                    model.apart(skip.song, there.artist, rate);
                    model.apart(there.song, skip.song, rate);
                    model.apart(there.artist, skip.song, rate);
                }
            }
        }
    }
    let mut mean = [0.0; DIMENSIONS];
    for (i, value) in model.input.iter().enumerate() {
        mean[i % DIMENSIONS] += value / tokens.len() as f64;
    }
    let mut vectors = Vec::with_capacity(model.input.len());
    for row in model.input.chunks_mut(DIMENSIONS) {
        check()?;
        let mut norm = 0.0;
        for (k, value) in row.iter_mut().enumerate() {
            *value -= mean[k];
            norm += *value * *value;
        }
        norm = norm.sqrt();
        for value in row {
            vectors.push(if norm == 0.0 {
                0.0
            } else {
                (*value / norm) as f32 as f64
            });
        }
    }
    check()?;
    Ok(json!({"tokens":tokens,"vectors":vectors,"positives":positives,"through":through}))
}

fn finish_session(session: Option<&mut Vec<Position<'_>>>, endorsed: &HashMap<&str, f64>) {
    if let Some(session) = session {
        for position in session {
            if let Some(value) = endorsed.get(position.song) {
                position.weight = position.weight.max(*value);
            }
        }
    }
}

struct Trainer {
    input: Vec<f64>,
    output: Vec<f64>,
    error: [f64; DIMENSIONS],
    random: DartRandom,
    cumulative: Vec<f64>,
    total: f64,
}

impl Trainer {
    fn negative(&mut self) -> i32 {
        let target = self.random.next_double() * self.total;
        let mut low = 0;
        let mut high = self.cumulative.len() - 1;
        while low < high {
            let middle = (low + high) >> 1;
            if self.cumulative[middle] <= target {
                low = middle + 1;
            } else {
                high = middle;
            }
        }
        low as i32
    }

    fn update(&mut self, center: i32, target: i32, label: f64, rate: f64) {
        let c = center as usize * DIMENSIONS;
        let t = target as usize * DIMENSIONS;
        let mut dot = 0.0;
        for k in 0..DIMENSIONS {
            dot += self.input[c + k] * self.output[t + k];
        }
        let gradient = (label - 1.0 / (1.0 + (-dot).exp())) * rate;
        for k in 0..DIMENSIONS {
            self.error[k] += gradient * self.output[t + k];
            self.output[t + k] += gradient * self.input[c + k];
        }
    }

    fn apply(&mut self, center: i32) {
        let c = center as usize * DIMENSIONS;
        for k in 0..DIMENSIONS {
            self.input[c + k] += self.error[k];
            self.error[k] = 0.0;
        }
    }

    fn together(&mut self, center: i32, context: i32, rate: f64) {
        if center < 0 || context < 0 || center == context {
            return;
        }
        self.update(center, context, 1.0, rate);
        for _ in 0..5 {
            let other = self.negative();
            if other != center && other != context {
                self.update(center, other, 0.0, rate);
            }
        }
        self.apply(center);
    }

    fn apart(&mut self, center: i32, context: i32, rate: f64) {
        if center < 0 || context < 0 || center == context {
            return;
        }
        self.update(center, context, 0.0, rate);
        self.apply(center);
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::cell::Cell;

    #[test]
    fn seeded_rng_matches_pinned_dart_vm() {
        let expected = [
            0.9667509138757331,
            0.37868351564893676,
            0.2873468299514055,
            0.5329176123040603,
            0.8553088058196988,
            0.6080254671138047,
            0.30687412066389064,
            0.27364317178817865,
            0.2886725186936596,
            0.8754835561891346,
            0.23683893544521994,
            0.8949821982072496,
        ];
        let mut random = DartRandom::new(0x7a57e);
        for value in expected {
            assert_eq!(random.next_double(), value);
        }
        let mut random = DartRandom::new(0x7a57e);
        for value in [21, 80, 59, 59, 4, 71, 52, 84, 20, 25, 48, 84] {
            assert_eq!(random.next_int(97), value);
        }
    }

    #[test]
    fn empty_history_preserves_empty_model() {
        assert_eq!(
            execute(&json!({"plays":[]}), &|| Ok(())).unwrap(),
            json!({"tokens":[],"vectors":[],"positives":0,"through":0})
        );
    }

    #[test]
    fn endorsements_are_not_counted_as_listens() {
        let result = execute(&json!({"plays":[{"id":9,"song":"a|song","artist":"a","atMicros":1,"kind":"loved","reward":1.0}]}), &||Ok(())).unwrap();
        assert_eq!(result["through"], 9);
        assert_eq!(result["positives"], 0);
        assert_eq!(result["tokens"], json!([]));
    }

    #[test]
    fn cancellation_stops_training() {
        let count = Cell::new(0);
        let result = execute(&json!({"plays":[]}), &|| {
            count.set(count.get() + 1);
            if count.get() > 1 {
                Err("cancelled".into())
            } else {
                Ok(())
            }
        });
        assert_eq!(result.unwrap_err(), "cancelled");
    }
}
