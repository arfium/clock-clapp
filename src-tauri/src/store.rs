//! The shared clock state (the "daemon"): alarms, timers, and the 1-second scheduler
//! that turns a due alarm/timer into a Clatch signal. The GUI (Tauri commands) and the
//! CLI (clappkit IPC) mutate it through the SAME `handle` method, so the two surfaces
//! never drift — "share state, not screens". Portable Rust; no platform code.
//!
//! This is a 1:1 port of the Swift `ClockStore` (`ClockStore.swift`, `ClockStore+View.swift`
//! and `TimeParse.swift` under native/Sources/clock): weekday-set repeats (1=Sun … 7=Sat),
//! the per-alarm `lastFired` minute guard, one-shot auto-disable, quiet-vs-wake signal
//! ids, id-based targets resolved to names only for display, and the same on-disk
//! shape (`{ alarms, timers, nextA, nextT }`) so an existing ~/.clock/clock.json loads.

use chrono::{DateTime, Datelike, Days, Local, NaiveDate, SecondsFormat, TimeZone, Timelike, Utc};
use serde::{Deserialize, Deserializer, Serialize, Serializer};
use serde_json::{json, Value};
use std::collections::BTreeSet;

/// The signal an app's pure state layer wants sent, and the roster row it displays, both
/// from clappkit: four apps had declared the identical structs locally and their roster
/// projections had already forked three ways.
pub use clappkit::{AgentRow, Emit};

/// The longest countdown `clock timer` will start: one year. Beyond that the addition to
/// `Local::now()` overflows `i64` — a panic in a debug build, and in release a wrapped
/// negative `endAt` that "completes" on the very next tick.
const MAX_TIMER_SECS: i64 = 365 * 86_400;

// ─────────────────────────────────────────────────────────────────────────────
// Days — repeat-day parsing/summary. Calendar weekday numbering: 1=Sun … 7=Sat,
// identical to Foundation's `Calendar`, so a Swift-written store decodes as-is.
// ─────────────────────────────────────────────────────────────────────────────

pub mod days {
    use std::collections::BTreeSet;

    pub const SHORT: [&str; 8] = ["", "Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"];

    /// The only weekday numbers this app understands (1=Sun … 7=Sat). Anything else on
    /// disk is dropped at decode: the load path is deliberately lenient so one bad field
    /// cannot wipe every alarm, and a value it lets through must never reach an index.
    pub fn valid(d: u32) -> bool {
        (1..=7).contains(&d)
    }

    fn set(v: &[u32]) -> BTreeSet<u32> {
        v.iter().copied().collect()
    }

    /// "weekdays" / "weekends" / "daily" / "mon,wed,fri" → a weekday set (empty = one-shot).
    pub fn parse(s: &str) -> BTreeSet<u32> {
        let raw = s.trim().to_ascii_lowercase();
        if raw.is_empty() {
            return BTreeSet::new();
        }
        match raw.as_str() {
            "daily" | "everyday" | "every day" | "all" => return set(&[1, 2, 3, 4, 5, 6, 7]),
            "weekdays" | "weekday" => return set(&[2, 3, 4, 5, 6]),
            "weekends" | "weekend" => return set(&[1, 7]),
            "once" | "never" => return BTreeSet::new(),
            _ => {}
        }
        // Matched on the first three letters, exactly like the Swift `Days.parse`.
        const MAP: [(&str, u32); 7] = [
            ("sun", 1), ("mon", 2), ("tue", 3), ("wed", 4), ("thu", 5), ("fri", 6), ("sat", 7),
        ];
        let mut out = BTreeSet::new();
        for tok in raw.split([',', ' ']).filter(|t| !t.is_empty()) {
            let head: String = tok.chars().take(3).collect();
            if let Some((_, d)) = MAP.iter().find(|(k, _)| *k == head) {
                out.insert(*d);
            }
        }
        out
    }

    /// "Once" | "Every day" | "Weekdays" | "Weekends" | "Mon Wed Fri".
    pub fn summary(days: &BTreeSet<u32>) -> String {
        if days.is_empty() {
            return "Once".into();
        }
        if days.len() == 7 {
            return "Every day".into();
        }
        if *days == set(&[2, 3, 4, 5, 6]) {
            return "Weekdays".into();
        }
        if *days == set(&[1, 7]) {
            return "Weekends".into();
        }
        // Total lookup, never an index: a hand-edited or older-build `repeatDays: [9]`
        // used to panic here, and `summary` runs for every alarm in every snapshot — so
        // the crash repeated on every command AND on every 1-second tick.
        days.iter()
            .filter_map(|d| SHORT.get(*d as usize).copied())
            .filter(|s| !s.is_empty())
            .collect::<Vec<_>>()
            .join(" ")
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// Models
// ─────────────────────────────────────────────────────────────────────────────

#[derive(Serialize, Clone)]
pub struct Alarm {
    pub id: String,
    pub hour: u32,   // 0..23
    pub minute: u32, // 0..59
    pub label: String,
    /// Free text. When `wake` is on, this note IS the prompt the woken agent receives.
    pub note: String,
    /// Calendar weekday 1=Sun … 7=Sat; EMPTY = one-shot.
    #[serde(rename = "repeatDays")]
    pub repeat_days: BTreeSet<u32>,
    pub enabled: bool,
    /// true → `alarm.fired` (run, wakes the agent); false → `alarm.quiet` (context).
    #[serde(rename = "wakeAgent")]
    pub wake: bool,
    /// The agent id that set it via the CLI (None = human/GUI). The OWNER — not editable.
    #[serde(rename = "ownerId")]
    pub owner: Option<String>,
    /// The agents this alarm fires at, by immutable agent id. EMPTY = broadcast.
    pub targets: Vec<String>,
    /// "yyyyMMddHHmm" guard so it fires once per matching minute.
    #[serde(rename = "lastFired")]
    pub last_fired: Option<String>,
}

/// Decoded by hand so a store written by an older build (or by the Swift app) still
/// loads: every field added after the first release is optional and falls back to its
/// default rather than throwing — otherwise one pre-existing clock.json would fail to
/// decode and silently wipe every alarm.
#[derive(Deserialize)]
struct AlarmDisk {
    id: String,
    hour: u32,
    minute: u32,
    #[serde(default)]
    label: String,
    #[serde(default)]
    note: String,
    #[serde(default, rename = "repeatDays")]
    repeat_days: Option<BTreeSet<u32>>,
    /// Legacy (the first Rust build): `"repeat": "once" | "daily" | "weekdays" | "weekends"`.
    #[serde(default, rename = "repeat")]
    repeat_legacy: Option<String>,
    #[serde(default = "yes")]
    enabled: bool,
    #[serde(default = "yes", rename = "wakeAgent", alias = "wake")]
    wake: bool,
    #[serde(default, rename = "ownerId", alias = "owner")]
    owner: Option<String>,
    #[serde(default)]
    targets: Option<Vec<String>>,
    #[serde(default, rename = "lastFired")]
    last_fired: Option<String>,
}

fn yes() -> bool {
    true
}

impl<'de> Deserialize<'de> for Alarm {
    fn deserialize<D: Deserializer<'de>>(d: D) -> Result<Alarm, D::Error> {
        let a = AlarmDisk::deserialize(d)?;
        // Range-check at the boundary, the same filter the wire (`days_from`) applies:
        // a lenient decode must not admit a weekday the rest of the app cannot name.
        let repeat_days: BTreeSet<u32> = a
            .repeat_days
            .or_else(|| a.repeat_legacy.as_deref().map(days::parse))
            .unwrap_or_default()
            .into_iter()
            .filter(|d| days::valid(*d))
            .collect();
        // A stored alarm without `targets` falls back to its owner (or broadcast).
        let targets = a.targets.unwrap_or_else(|| a.owner.iter().cloned().collect());
        Ok(Alarm {
            id: a.id,
            hour: a.hour,
            minute: a.minute,
            label: a.label,
            note: a.note,
            repeat_days,
            enabled: a.enabled,
            wake: a.wake,
            owner: a.owner,
            targets,
            last_fired: a.last_fired,
        })
    }
}

#[derive(Serialize, Clone)]
pub struct Timer {
    pub id: String,
    pub label: String,
    pub total: i64, // seconds
    /// Wall-clock fire time (valid while running). Written as ISO-8601 UTC, like Swift's
    /// `JSONEncoder.dateEncodingStrategy = .iso8601`.
    #[serde(rename = "endAt", serialize_with = "ser_iso")]
    pub end_at: i64,
    /// Some(remaining secs) when paused (frozen); None while running.
    #[serde(rename = "pausedRemaining")]
    pub paused: Option<i64>,
    pub done: bool,
    #[serde(rename = "ownerId")]
    pub owner: Option<String>,
}

#[derive(Deserialize)]
struct TimerDisk {
    id: String,
    #[serde(default)]
    label: String,
    #[serde(default)]
    total: i64,
    #[serde(rename = "endAt", alias = "end_at")]
    end_at: Instant,
    #[serde(default, rename = "pausedRemaining", alias = "paused")]
    paused: Option<i64>,
    #[serde(default)]
    done: bool,
    #[serde(default, rename = "ownerId", alias = "owner")]
    owner: Option<String>,
}

/// `endAt` on disk is an ISO-8601 string (Swift, and this build) or a bare unix-seconds
/// number (the first Rust build). Accept both.
#[derive(Deserialize)]
#[serde(untagged)]
enum Instant {
    Unix(i64),
    Iso(String),
}

impl Instant {
    fn secs(self) -> i64 {
        match self {
            Instant::Unix(n) => n,
            Instant::Iso(s) => DateTime::parse_from_rfc3339(&s)
                .map(|d| d.timestamp())
                .unwrap_or_else(|_| Local::now().timestamp()),
        }
    }
}

fn ser_iso<S: Serializer>(secs: &i64, s: S) -> Result<S::Ok, S::Error> {
    s.serialize_str(&iso(*secs))
}

/// Unix seconds → "2026-07-29T11:30:00Z" (what `ISO8601DateFormatter` writes).
fn iso(secs: i64) -> String {
    Utc.timestamp_opt(secs, 0)
        .single()
        .unwrap_or_else(Utc::now)
        .to_rfc3339_opts(SecondsFormat::Secs, true)
}

impl<'de> Deserialize<'de> for Timer {
    fn deserialize<D: Deserializer<'de>>(d: D) -> Result<Timer, D::Error> {
        let t = TimerDisk::deserialize(d)?;
        Ok(Timer {
            id: t.id,
            label: t.label,
            total: t.total,
            end_at: t.end_at.secs(),
            paused: t.paused,
            done: t.done,
            owner: t.owner,
        })
    }
}

impl Timer {
    fn is_running(&self) -> bool {
        self.paused.is_none() && !self.done
    }
    fn remaining(&self, now: i64) -> i64 {
        if self.done {
            return 0;
        }
        match self.paused {
            Some(r) => r,
            None => (self.end_at - now).max(0),
        }
    }
}

pub struct Store {
    pub alarms: Vec<Alarm>,
    pub timers: Vec<Timer>,
    next_a: u32,
    next_t: u32,
    /// The bound agents, mirrored from the control pipe's roster (for id ↔ name display).
    /// Not persisted — Clatch owns it and re-pushes it on every bind change.
    agents: Vec<AgentRow>,
    /// Something durable changed since the last `save`. The read-only verbs (`state`,
    /// `list`, `now`) leave it false, so `clock now` no longer rewrites clock.json.
    dirty: bool,
}

impl Default for Store {
    fn default() -> Store {
        Store {
            alarms: Vec::new(),
            timers: Vec::new(),
            next_a: 1,
            next_t: 1,
            agents: Vec::new(),
            dirty: false,
        }
    }
}

#[derive(Serialize, Deserialize, Default)]
struct Persist {
    #[serde(default)]
    alarms: Vec<Alarm>,
    #[serde(default)]
    timers: Vec<Timer>,
    #[serde(default, rename = "nextA", alias = "next_alarm")]
    next_a: u32,
    #[serde(default, rename = "nextT", alias = "next_timer")]
    next_t: u32,
}

impl Store {
    // MARK: roster (id ↔ name)

    pub fn set_agents(&mut self, agents: Vec<AgentRow>) {
        self.agents = agents;
    }

    /// Whether anything durable changed since the last call, clearing the flag. The one
    /// gate on `save`: a pure read must not rewrite the store (and must not take the
    /// blocking write with the lock held while the scheduler waits for it).
    pub fn take_dirty(&mut self) -> bool {
        std::mem::take(&mut self.dirty)
    }

    /// Resolve an agent id → its current display name (falls back to the id if the agent
    /// left the roster). Name is display-only; id is the wire key. This reads the store's
    /// own roster mirror rather than `Control::name_of`, because `handle` is sync and
    /// side-effect-free by design — it never touches the pipe.
    fn name_for(&self, id: &str) -> Option<String> {
        self.agents.iter().find(|a| a.id == id).map(|a| a.name.clone())
    }

    /// A display name (what a human types in `--to`) → an agent id. Swift matches on name
    /// only; we also accept a literal id so an agent can pass its own id straight through.
    fn id_for_name(&self, n: &str) -> Option<String> {
        self.agents
            .iter()
            .find(|a| a.name.eq_ignore_ascii_case(n))
            .or_else(|| self.agents.iter().find(|a| a.id == n))
            .map(|a| a.id.clone())
    }

    /// `--to` / `targets` → the agent ids to wake. `None` = "not specified" (fall back to
    /// the owner default); `Some([])` = broadcast to every bound agent.
    fn targets_from(&self, req: &Value) -> Option<Vec<String>> {
        if let Some(arr) = req.get("targets").and_then(Value::as_array) {
            return Some(arr.iter().filter_map(Value::as_str).map(String::from).collect());
        }
        let raw = req.get("to").and_then(Value::as_str)?.trim().to_string();
        if raw.is_empty() {
            return None;
        }
        let low = raw.to_ascii_lowercase();
        if low == "everyone" || low == "all" || low == "any" {
            return Some(vec![]);
        }
        Some(
            raw.split([',', ' '])
                .filter(|t| !t.is_empty())
                .filter_map(|n| self.id_for_name(n))
                .collect(),
        )
    }

    // MARK: scheduler

    /// One tick (call ~every second). Emits due alarm/timer signals; minute-granular for
    /// alarms, guarded once per matching minute by each alarm's `lastFired`.
    pub fn tick(&mut self, now: DateTime<Local>) -> Vec<Emit> {
        let mut emits = Vec::new();
        let now_s = now.timestamp();

        // Timers: fire any running timer whose end has arrived (including one that
        // expired while the app was closed — its endAt is already past on the first tick).
        for i in 0..self.timers.len() {
            if self.timers[i].is_running() && self.timers[i].end_at <= now_s {
                self.timers[i].done = true;
                emits.push(self.timer_emit(i, now_s));
            }
        }

        // Alarms: once per matching minute.
        let key = format!(
            "{:04}{:02}{:02}{:02}{:02}",
            now.year(),
            now.month(),
            now.day(),
            now.hour(),
            now.minute()
        );
        let weekday = now.weekday().number_from_sunday(); // 1=Sun … 7=Sat
        let (h, m) = (now.hour(), now.minute());
        for i in 0..self.alarms.len() {
            let a = &self.alarms[i];
            if !a.enabled || a.last_fired.as_deref() == Some(key.as_str()) {
                continue;
            }
            let day_ok = a.repeat_days.is_empty() || a.repeat_days.contains(&weekday);
            if a.hour == h && a.minute == m && day_ok {
                emits.push(self.alarm_emit(i, now_s));
                self.alarms[i].last_fired = Some(key.clone());
                if self.alarms[i].repeat_days.is_empty() {
                    self.alarms[i].enabled = false; // one-shot auto-disables
                }
            }
        }
        if !emits.is_empty() {
            self.dirty = true; // lastFired / the one-shot disable must survive a restart
        }
        emits
    }

    fn alarm_emit(&self, i: usize, at: i64) -> Emit {
        let a = &self.alarms[i];
        // The signal NAME decides wake-vs-notify; a type is fixed at declaration.
        let id = if a.wake { "alarm.fired" } else { "alarm.quiet" };
        let mut payload = json!({
            "id": a.id,
            "label": a.label,
            "at": iso(at),
            "time": format!("{:02}:{:02}", a.hour, a.minute),
            // display: resolve target ids → current names for the agent to read
            "to": if a.targets.is_empty() { "everyone".to_string() } else { self.names_of(&a.targets).join(",") },
        });
        // The note rides along as the agent's instruction: on `alarm.fired` (run) it is
        // effectively the prompt for the turn this signal starts.
        if !a.note.is_empty() {
            payload["note"] = json!(a.note);
        }
        if let Some(owner) = &a.owner {
            payload["for"] = json!(self.name_for(owner).unwrap_or_else(|| owner.clone()));
        }
        // Wake exactly the chosen agents; empty broadcasts to every bound agent.
        Emit { id: id.into(), target: a.targets.clone(), payload }
    }

    fn timer_emit(&self, i: usize, at: i64) -> Emit {
        let t = &self.timers[i];
        let mut payload = json!({
            "id": t.id,
            "label": t.label,
            "seconds": t.total.to_string(),
            "at": iso(at),
        });
        if let Some(owner) = &t.owner {
            payload["for"] = json!(self.name_for(owner).unwrap_or_else(|| owner.clone()));
        }
        Emit {
            id: "timer.done".into(),
            target: t.owner.clone().into_iter().collect(), // the setter
            payload,
        }
    }

    // MARK: the one command handler (GUI + CLI both call this)

    /// Apply a command and return `(response, signals-to-emit)`. `cmd` is a JSON object
    /// `{ "cmd": "...", ... }`; `caller` is the CLI caller's agent id (None = GUI/human).
    pub fn handle(&mut self, req: &Value, caller: Option<String>) -> (Value, Vec<Emit>) {
        let cmd = req.get("cmd").and_then(Value::as_str).unwrap_or("");
        let text = |k: &str| req.get(k).and_then(Value::as_str);
        let mut emits = Vec::new();

        // Only the three pure reads leave the store clean. Marking every other verb dirty
        // — including one that goes on to fail — keeps the old always-save behaviour for
        // anything that could have mutated, and costs one needless write on a rejection.
        if !matches!(cmd, "state" | "list" | "now") {
            self.dirty = true;
        }

        let resp = match cmd {
            // `now` is `list` without the listing — the snapshot already carries `nowText`.
            "state" | "list" | "now" => self.snapshot(),

            "alarm" | "set" => {
                // `set` is the smart alias: a duration → a timer, a clock time → an alarm.
                if cmd == "set" {
                    let raw = text("when").unwrap_or("");
                    if parse_hhmm(raw).is_none() && parse_dur(raw).is_some() {
                        return self.handle(&json!({ "cmd": "timer", "dur": raw, "label": text("label").unwrap_or("") }), caller);
                    }
                }
                let (hour, minute) = match hm_from(req) {
                    Some(v) => v,
                    None => {
                        return (
                            err(&format!(
                                "bad time: {} — try 7:30, 07:30, or 7:30am",
                                text("when").unwrap_or("")
                            )),
                            emits,
                        )
                    }
                };
                let targets = self.targets_from(req);
                let a = self.add_alarm(
                    hour,
                    minute,
                    text("label").unwrap_or("").trim().to_string(),
                    text("note").unwrap_or("").trim().to_string(),
                    days_from(req).unwrap_or_default(),
                    // The GUI's "Wake the agent" switch sends `wake`; the CLI sends `--quiet`.
                    req.get("wake")
                        .and_then(Value::as_bool)
                        .unwrap_or_else(|| !req.get("quiet").and_then(Value::as_bool).unwrap_or(false)),
                    targets,
                    caller.clone(),
                );
                // A human (GUI) add tells every agent about it (broadcast, context);
                // an agent's own add is silent.
                if caller.is_none() {
                    let mut p = json!({
                        "id": a.id,
                        "label": a.label,
                        "time": format!("{hour:02}:{minute:02}"),
                    });
                    if !a.note.is_empty() {
                        p["note"] = json!(a.note);
                    }
                    emits.push(Emit { id: "alarm.set".into(), target: vec![], payload: p });
                }
                let id = a.id.clone();
                let mut r = self.snapshot();
                r["alarm"] = self.alarm_dto_by_id(&id).unwrap_or(Value::Null);
                r
            }

            // Partial update: every field you omit keeps its current value. Ownership is
            // deliberately NOT editable — whoever set it stays the one it wakes.
            "edit" | "update" => {
                let id = text("id").unwrap_or("").to_string();
                let Some(i) = self.alarms.iter().position(|a| a.id == id) else {
                    return (err(&format!("no such alarm: {id}")), emits);
                };
                let (mut hour, mut minute) = (self.alarms[i].hour, self.alarms[i].minute);
                if req.get("when").is_some() || req.get("hour").is_some() {
                    match hm_from(req) {
                        Some(v) => {
                            hour = v.0;
                            minute = v.1;
                        }
                        None => {
                            return (
                                err(&format!(
                                    "bad time: {} — try 7:30, 07:30, or 7:30am",
                                    text("when").unwrap_or("")
                                )),
                                emits,
                            )
                        }
                    }
                }
                let targets = self.targets_from(req).unwrap_or_else(|| self.alarms[i].targets.clone());
                let days = days_from(req).unwrap_or_else(|| self.alarms[i].repeat_days.clone());
                let a = &mut self.alarms[i];
                a.hour = hour;
                a.minute = minute;
                if let Some(v) = text("label") {
                    a.label = v.trim().to_string();
                }
                if let Some(v) = text("note") {
                    a.note = v.trim().to_string();
                }
                a.repeat_days = days;
                if let Some(q) = req.get("quiet").and_then(Value::as_bool) {
                    a.wake = !q;
                }
                if let Some(w) = req.get("wake").and_then(Value::as_bool) {
                    a.wake = w;
                }
                a.targets = targets;
                // Re-arm: moving an alarm onto the current minute still rings instead of
                // being swallowed by the once-per-minute guard.
                a.last_fired = None;
                self.sort_alarms();
                let mut r = self.snapshot();
                r["alarm"] = self.alarm_dto_by_id(&id).unwrap_or(Value::Null);
                r
            }

            "timer" => {
                let raw = text("dur").or_else(|| text("when")).unwrap_or("");
                // The GUI drum sends plain seconds; the CLI sends "10m" / "1h30m" / "90s"
                // (and, as this CLI has always documented, a bare number = seconds).
                let secs = req
                    .get("seconds")
                    .and_then(Value::as_i64)
                    .or_else(|| parse_dur(raw))
                    .or_else(|| raw.trim().parse::<i64>().ok())
                    .unwrap_or(0);
                // Clamped, not just positive: `clock timer 9223372036854775807s` parses
                // cleanly (parse_dur is overflow-checked) and then overflowed the
                // `now + seconds` addition — a panic in a debug build, an instantly-
                // "done" timer in release. The ceiling is also the actionable message.
                if secs <= 0 || secs > MAX_TIMER_SECS {
                    return (err("bad duration — use e.g. 10m, 1h30m, 90s (max 365d)"), emits);
                }
                let t = self.add_timer(secs, text("label").unwrap_or("").trim().to_string(), caller.clone());
                let id = t.id.clone();
                let mut r = self.snapshot();
                r["timer"] = self.timer_dto_by_id(&id).unwrap_or(Value::Null);
                r
            }

            "cancel" => {
                let id = text("id").unwrap_or("");
                let before = self.alarms.len() + self.timers.len();
                self.alarms.retain(|a| a.id != id);
                self.timers.retain(|t| t.id != id);
                if self.alarms.len() + self.timers.len() < before {
                    self.snapshot()
                } else {
                    err(&format!("no alarm or timer with id {id}"))
                }
            }

            // Toggling/setting `enabled` re-arms the alarm (clears the minute guard).
            "toggle" | "enable" => {
                let id = text("id").unwrap_or("").to_string();
                let on = req.get("on").and_then(Value::as_bool);
                let done = match self.alarms.iter_mut().find(|a| a.id == id) {
                    Some(a) => {
                        a.enabled = match on {
                            Some(v) if cmd == "enable" => v,
                            _ => !a.enabled,
                        };
                        a.last_fired = None;
                        true
                    }
                    None => false,
                };
                if done {
                    self.snapshot()
                } else {
                    err(&format!("no alarm with id {id}"))
                }
            }

            "pause" => {
                let id = text("id").unwrap_or("").to_string();
                let now = Local::now().timestamp();
                let outcome: Result<(), String> = match self.timers.iter_mut().find(|t| t.id == id) {
                    Some(t) if t.is_running() => {
                        let r = t.remaining(now);
                        t.paused = Some(r); // frozen
                        Ok(())
                    }
                    Some(_) => Err(format!("timer {id} is not running")),
                    None => Err(format!("no timer with id {id}")),
                };
                match outcome {
                    Ok(()) => self.snapshot(),
                    Err(e) => err(&e),
                }
            }

            "resume" => {
                let id = text("id").unwrap_or("").to_string();
                let now = Local::now().timestamp();
                let outcome: Result<(), String> = match self.timers.iter_mut().find(|t| t.id == id) {
                    Some(t) => match t.paused.take() {
                        Some(r) => {
                            t.end_at = now + r;
                            Ok(())
                        }
                        None => Err(format!("timer {id} is not paused")),
                    },
                    None => Err(format!("no timer with id {id}")),
                };
                match outcome {
                    Ok(()) => self.snapshot(),
                    Err(e) => err(&e),
                }
            }

            other => err(&format!("unknown command: {other}")),
        };
        (resp, emits)
    }

    // MARK: mutations (the GUI and the CLI call the SAME ones)

    #[allow(clippy::too_many_arguments)]
    fn add_alarm(
        &mut self,
        hour: u32,
        minute: u32,
        label: String,
        note: String,
        repeat_days: BTreeSet<u32>,
        wake: bool,
        targets: Option<Vec<String>>,
        caller: Option<String>,
    ) -> Alarm {
        let owner = caller; // the CLATCH_AGENT_ID that set it (None = human/GUI)
        // An explicit selection wins; otherwise a CLI alarm wakes its setter, a GUI alarm
        // broadcasts (empty). Targets and owner are agent IDS.
        let resolved = targets.unwrap_or_else(|| owner.iter().cloned().collect());
        let a = Alarm {
            id: format!("a{}", self.next_a),
            hour,
            minute,
            label,
            note,
            repeat_days,
            enabled: true,
            wake,
            owner,
            targets: resolved,
            last_fired: None,
        };
        self.next_a += 1;
        self.alarms.push(a.clone());
        self.sort_alarms();
        a
    }

    fn add_timer(&mut self, seconds: i64, label: String, caller: Option<String>) -> Timer {
        let t = Timer {
            id: format!("t{}", self.next_t),
            label,
            total: seconds,
            // Checked even though the caller clamps to MAX_TIMER_SECS: this is the one
            // arithmetic in the store that can overflow, and a panic here kills the IPC
            // task mid-request (the agent sees "the app closed the connection").
            end_at: Local::now().timestamp().saturating_add(seconds),
            paused: None,
            done: false,
            owner: caller,
        };
        self.next_t += 1;
        self.timers.push(t.clone());
        t
    }

    fn sort_alarms(&mut self) {
        self.alarms
            .sort_by(|a, b| (a.hour, a.minute, &a.id).cmp(&(b.hour, b.minute, &b.id)));
    }

    // MARK: projection for GUI + CLI

    /// Every view of the store — the CLI's response, the webview's invoke reply, and the
    /// pushed `state` event — is one of these, stamped with a monotonic `rev` so the two
    /// writers feeding the window cannot drag it backwards (clappkit::snapshot).
    pub fn snapshot(&self) -> Value {
        let now = Local::now();
        clappkit::snapshot::with_rev(json!({
            "ok": true,
            "now": now.timestamp(),
            "nowText": now.format("%b %-d %H:%M:%S").to_string(),
            "alarms": self.alarms.iter().map(|a| self.alarm_dto(a, now)).collect::<Vec<_>>(),
            "timers": self.timers.iter().map(|t| self.timer_dto(t, now.timestamp())).collect::<Vec<_>>(),
            "agents": self.agents.iter().map(|a| json!({
                "id": a.id, "name": a.name,
                // clappkit's AgentRow is `Option<String>` (Clatch sends "" when it has
                // nothing); the wire keeps the empty string it has always carried.
                "backend": a.backend.clone().unwrap_or_default(),
                "model": a.model, "avatar": a.avatar,
            })).collect::<Vec<_>>(),
        }))
    }

    fn alarm_dto(&self, a: &Alarm, now: DateTime<Local>) -> Value {
        let next = next_fire(a, now);
        let next_text = if a.enabled {
            next.map(|d| relative(d.timestamp(), now.timestamp())).unwrap_or_else(|| "off".into())
        } else {
            "off".into()
        };
        json!({
            "id": a.id,
            "hour": a.hour,
            "minute": a.minute,
            "time": format!("{:02}:{:02}", a.hour, a.minute),
            "label": a.label,
            "note": a.note,
            "repeat": days::summary(&a.repeat_days),
            "days": a.repeat_days.iter().collect::<Vec<_>>(),
            "enabled": a.enabled,
            "wake": a.wake,
            // display-only: the owner's CURRENT name (the wire stores the id)
            "owner": a.owner.as_deref().map(|id| self.name_for(id).unwrap_or_else(|| id.to_string())),
            "ownerId": a.owner,
            "targets": a.targets,
            "wakes": self.wakes_text(&a.targets),
            "wakesShort": self.wakes_short(&a.targets),
            "detail": detail(a),
            "nextText": next_text,
            "nextAt": next.map(|d| d.timestamp()),
        })
    }

    fn timer_dto(&self, t: &Timer, now: i64) -> Value {
        let rem = t.remaining(now);
        json!({
            "id": t.id,
            "label": t.label,
            "remaining": rem,
            "remainingText": fmt_dur(rem),
            "total": t.total,
            "running": t.is_running(),
            "done": t.done,
            "owner": t.owner.as_deref().map(|id| self.name_for(id).unwrap_or_else(|| id.to_string())),
            "ownerId": t.owner,
            "endAt": t.end_at,
            "endText": if t.done { "done".to_string() }
                       else if t.is_running() { format!("ends {}", hhmm(t.end_at)) }
                       else { "paused".to_string() },
        })
    }

    fn alarm_dto_by_id(&self, id: &str) -> Option<Value> {
        let now = Local::now();
        self.alarms.iter().find(|a| a.id == id).map(|a| self.alarm_dto(a, now))
    }
    fn timer_dto_by_id(&self, id: &str) -> Option<Value> {
        let now = Local::now().timestamp();
        self.timers.iter().find(|t| t.id == id).map(|t| self.timer_dto(t, now))
    }

    fn names_of(&self, targets: &[String]) -> Vec<String> {
        targets
            .iter()
            .map(|id| self.name_for(id).unwrap_or_else(|| id.clone()))
            .collect()
    }

    /// "everyone" | "alice" | "alice, bob" — the sheet's picker label / the CLI's `→`.
    fn wakes_text(&self, targets: &[String]) -> String {
        if targets.is_empty() {
            "everyone".into()
        } else {
            self.names_of(targets).join(", ")
        }
    }

    /// The alarm row's tag: "alice" · "alice, bob" · "alice +2" (empty when broadcast).
    fn wakes_short(&self, targets: &[String]) -> String {
        let names = self.names_of(targets);
        match names.len() {
            0 => String::new(),
            1 | 2 => names.join(", "),
            n => format!("{} +{}", names[0], n - 1),
        }
    }

    // MARK: persistence — clappkit owns WHERE it lives and HOW it is written

    /// `$CLATCH_DATA_DIR/clock.json`, else `~/.clock/clock.json` (`%LOCALAPPDATA%\clock`
    /// on Windows). One resolver for every clapp: `PathBuf::join` rather than a
    /// hand-interpolated `"{home}/.clock"`, an empty `CLATCH_DATA_DIR` treated as unset
    /// (it used to send the store into the process cwd — the install dir under Clatch),
    /// and no `"."` fallback at all.
    pub fn path() -> std::path::PathBuf {
        clappkit::paths::data_file("clock", "clock.json")
    }

    pub fn load() -> Store {
        let mut store = Store::default();
        let Some(p) = clappkit::store::load_json::<Persist>(&Store::path()) else {
            return store; // first run, or a damaged file clappkit already reported
        };
        store.alarms = p.alarms;
        // Drop finished timers on load; a still-running one that expired while we
        // were closed fires on the first tick (its endAt is already past).
        store.timers = p.timers.into_iter().filter(|t| !t.done).collect();
        // Advance the id counters past the highest id actually on disk.
        let hi_a = store.alarms.iter().map(|a| suffix(&a.id)).max().unwrap_or(0);
        let hi_t = store.timers.iter().map(|t| suffix(&t.id)).max().unwrap_or(0);
        store.next_a = p.next_a.max(hi_a + 1).max(1);
        store.next_t = p.next_t.max(hi_t + 1).max(1);
        store.sort_alarms();
        store
    }

    /// Write the alarms and timers out. clappkit's `save_json` is tmp → fsync → rename →
    /// directory fsync, at mode 0600 — so a power loss cannot leave a truncated file that
    /// the lenient load path would read as "fresh install" and silently start empty from.
    pub fn save(&self) {
        let p = Persist {
            alarms: self.alarms.clone(),
            timers: self.timers.clone(),
            next_a: self.next_a,
            next_t: self.next_t,
        };
        clappkit::store::save_json(&Store::path(), &p);
    }
}

/// The numeric part of an "a3" / "t7" id (0 if it isn't one).
fn suffix(id: &str) -> u32 {
    id.get(1..).and_then(|n| n.parse().ok()).unwrap_or(0)
}

fn err(msg: &str) -> Value {
    json!({ "ok": false, "error": msg })
}

/// The alarm row's second line — Apple's `ALARM_DETAIL_FORMAT = "%1$@, %2$@"`.
fn detail(a: &Alarm) -> String {
    let label = if a.label.is_empty() { "Alarm" } else { a.label.as_str() };
    let rep = days::summary(&a.repeat_days);
    let mut s = if rep == "Once" { label.to_string() } else { format!("{label}, {rep}") };
    if !a.wake {
        s.push_str(", quiet");
    }
    s
}

// ─────────────────────────────────────────────────────────────────────────────
// Request helpers
// ─────────────────────────────────────────────────────────────────────────────

/// `{ hour, minute }` (the GUI's drum) or `{ when: "7:30am" }` (the CLI).
fn hm_from(req: &Value) -> Option<(u32, u32)> {
    if let (Some(h), Some(m)) = (
        req.get("hour").and_then(Value::as_u64),
        req.get("minute").and_then(Value::as_u64),
    ) {
        if h < 24 && m < 60 {
            return Some((h as u32, m as u32));
        }
        return None;
    }
    req.get("when").and_then(Value::as_str).and_then(parse_hhmm)
}

/// `{ days: [2,4,6] }` (the GUI's day pills) or `{ repeat: "weekdays" }` (the CLI).
/// `None` = "not specified" so an `edit` keeps whatever the alarm already had.
fn days_from(req: &Value) -> Option<BTreeSet<u32>> {
    if let Some(arr) = req.get("days").and_then(Value::as_array) {
        return Some(
            arr.iter()
                .filter_map(Value::as_u64)
                .filter(|d| (1..=7).contains(d))
                .map(|d| d as u32)
                .collect(),
        );
    }
    req.get("repeat")
        .or_else(|| req.get("days"))
        .and_then(Value::as_str)
        .map(days::parse)
}

/// The next wall-clock occurrence of an alarm (today if still ahead, else the next
/// matching weekday; for one-shots, today or tomorrow).
fn next_fire(a: &Alarm, from: DateTime<Local>) -> Option<DateTime<Local>> {
    for add in 0..=7u64 {
        let Some(date) = from.date_naive().checked_add_days(Days::new(add)) else {
            continue;
        };
        let Some(cand) = local_at(date, a.hour, a.minute) else {
            continue;
        };
        if cand <= from {
            continue;
        }
        let wd = cand.weekday().number_from_sunday();
        if a.repeat_days.is_empty() || a.repeat_days.contains(&wd) {
            return Some(cand);
        }
    }
    None
}

fn local_at(date: NaiveDate, h: u32, m: u32) -> Option<DateTime<Local>> {
    let naive = date.and_hms_opt(h, m, 0)?;
    Local.from_local_datetime(&naive).earliest()
}

/// Parse "HH:MM" / "7:30" / "7:30am" / "7am" / "19:30" → (hour 0..23, minute 0..59).
fn parse_hhmm(s: &str) -> Option<(u32, u32)> {
    let s = s.trim().to_ascii_lowercase();
    let (body, pm) = if let Some(b) = s.strip_suffix("am") {
        (b.trim(), Some(false))
    } else if let Some(b) = s.strip_suffix("pm") {
        (b.trim(), Some(true))
    } else {
        (s.as_str(), None)
    };
    let mut parts = body.split(':');
    let h: u32 = parts.next()?.trim().parse().ok()?;
    if h > 23 {
        return None;
    }
    let minute: u32 = match parts.next() {
        Some(m) => m.trim().parse().ok()?,
        None => 0,
    };
    if minute > 59 {
        return None;
    }
    // 12am → 0, 12pm → 12.
    let hour = match pm {
        Some(true) => {
            if h == 12 {
                12
            } else {
                h + 12
            }
        }
        Some(false) => {
            if h == 12 {
                0
            } else {
                h
            }
        }
        None => h,
    };
    if hour > 23 {
        return None;
    }
    Some((hour, minute))
}

/// Parse a compound duration — "10m", "1h30m", "90s", "2d" — into seconds.
/// Overflow-checked; a trailing bare number (no unit) is invalid, exactly like Swift's
/// `TimeParse.duration` (the CLI's own bare-number tolerance is applied at the call site).
fn parse_dur(s: &str) -> Option<i64> {
    let str = s.trim().to_ascii_lowercase();
    if str.is_empty() {
        return None;
    }
    let mut total: i64 = 0;
    let mut num = String::new();
    let mut saw_unit = false;
    for ch in str.chars() {
        if ch.is_ascii_digit() {
            num.push(ch);
        } else {
            let n: i64 = num.parse().ok()?;
            let unit: i64 = match ch {
                's' => 1,
                'm' => 60,
                'h' => 3600,
                'd' => 86_400,
                _ => return None,
            };
            total = total.checked_add(n.checked_mul(unit)?)?;
            num.clear();
            saw_unit = true;
        }
    }
    if !num.is_empty() || !saw_unit {
        return None;
    }
    Some(total)
}

/// Countdown display: "9:58", "1:04:58" (drops hours < 1h, drops leading zeros).
fn fmt_dur(secs: i64) -> String {
    let s = secs.max(0);
    let (h, m, sec) = (s / 3600, (s % 3600) / 60, s % 60);
    if h > 0 {
        format!("{h}:{m:02}:{sec:02}")
    } else {
        format!("{m}:{sec:02}")
    }
}

/// A unix instant → "15:47" (24h; the webview re-formats to the user's locale).
fn hhmm(secs: i64) -> String {
    Local
        .timestamp_opt(secs, 0)
        .single()
        .unwrap_or_else(Local::now)
        .format("%H:%M")
        .to_string()
}

/// "in 9m 58s" / "2m ago" / "now".
fn relative(target: i64, now: i64) -> String {
    let delta = target - now;
    if delta == 0 {
        return "now".into();
    }
    let text = compact(delta.abs());
    if delta > 0 {
        format!("in {text}")
    } else {
        format!("{text} ago")
    }
}

/// Seconds → compact "1h 5m", "58s", "2d 3h" (at most two units).
fn compact(seconds: i64) -> String {
    if seconds <= 0 {
        return "0s".into();
    }
    const UNITS: [(&str, i64); 4] = [("d", 86_400), ("h", 3600), ("m", 60), ("s", 1)];
    let mut parts: Vec<String> = Vec::new();
    let mut rem = seconds;
    for (name, size) in UNITS {
        if parts.len() >= 2 {
            break;
        }
        let q = rem / size;
        if q > 0 {
            parts.push(format!("{q}{name}"));
            rem -= q * size;
        }
    }
    if parts.is_empty() {
        "0s".into()
    } else {
        parts.join(" ")
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parses_times() {
        assert_eq!(parse_hhmm("7:30"), Some((7, 30)));
        assert_eq!(parse_hhmm("07:30"), Some((7, 30)));
        assert_eq!(parse_hhmm("7:30am"), Some((7, 30)));
        assert_eq!(parse_hhmm("7pm"), Some((19, 0)));
        assert_eq!(parse_hhmm("12am"), Some((0, 0)));
        assert_eq!(parse_hhmm("12pm"), Some((12, 0)));
        assert_eq!(parse_hhmm("19:30"), Some((19, 30)));
        assert_eq!(parse_hhmm("25:00"), None);
    }

    #[test]
    fn parses_durations() {
        assert_eq!(parse_dur("10m"), Some(600));
        assert_eq!(parse_dur("1h30m"), Some(5400));
        assert_eq!(parse_dur("90s"), Some(90));
        assert_eq!(parse_dur("2d"), Some(172_800));
        assert_eq!(parse_dur("45"), None); // a bare number is not a duration
    }

    #[test]
    fn formats() {
        assert_eq!(fmt_dur(598), "9:58");
        assert_eq!(fmt_dur(3898), "1:04:58");
        assert_eq!(compact(3900), "1h 5m");
        assert_eq!(compact(58), "58s");
        assert_eq!(compact(183_600), "2d 3h");
    }

    #[test]
    fn day_sets() {
        assert_eq!(days::summary(&days::parse("")), "Once");
        assert_eq!(days::summary(&days::parse("daily")), "Every day");
        assert_eq!(days::summary(&days::parse("weekdays")), "Weekdays");
        assert_eq!(days::summary(&days::parse("weekends")), "Weekends");
        assert_eq!(days::summary(&days::parse("mon,wed,fri")), "Mon Wed Fri");
    }

    /// A store with the roster loaded, used by the behaviour tests below.
    fn store() -> Store {
        let mut s = Store::default();
        s.set_agents(vec![
            AgentRow { id: "1001".into(), name: "alice".into(), ..Default::default() },
            AgentRow { id: "1002".into(), name: "bob".into(), ..Default::default() },
        ]);
        s
    }

    fn at(h: u32, m: u32) -> DateTime<Local> {
        local_at(Local::now().date_naive(), h, m).unwrap()
    }

    #[test]
    fn gui_add_broadcasts_and_announces() {
        let mut s = store();
        let (r, emits) = s.handle(&json!({ "cmd": "alarm", "when": "7:30", "label": "standup" }), None);
        assert_eq!(r["ok"], json!(true));
        assert_eq!(r["alarms"][0]["id"], json!("a1"));
        assert_eq!(r["alarms"][0]["wakes"], json!("everyone")); // GUI alarm = broadcast
        assert_eq!(r["alarms"][0]["owner"], Value::Null);
        // The human scheduling one is announced to every agent as context.
        assert_eq!(emits.len(), 1);
        assert_eq!(emits[0].id, "alarm.set");
        assert!(emits[0].target.is_empty());
        assert_eq!(emits[0].payload["time"], json!("07:30"));
    }

    #[test]
    fn cli_add_defaults_to_its_setter_and_is_silent() {
        let mut s = store();
        let (r, emits) = s.handle(
            &json!({ "cmd": "alarm", "when": "7:30am", "label": "x", "note": " ship it " }),
            Some("1001".into()),
        );
        assert!(emits.is_empty()); // an agent's own add is silent
        assert_eq!(r["alarms"][0]["owner"], json!("alice")); // id resolved for display
        assert_eq!(r["alarms"][0]["targets"], json!(["1001"])); // wakes its setter
        assert_eq!(r["alarms"][0]["note"], json!("ship it")); // trimmed
    }

    #[test]
    fn to_names_resolve_to_ids_and_everyone_broadcasts() {
        let mut s = store();
        s.handle(&json!({ "cmd": "alarm", "when": "7:30", "to": "alice,bob" }), Some("1002".into()));
        assert_eq!(s.alarms[0].targets, vec!["1001".to_string(), "1002".to_string()]);
        let (r, _) = s.handle(&json!({ "cmd": "edit", "id": "a1", "to": "everyone" }), None);
        assert_eq!(r["alarms"][0]["wakes"], json!("everyone"));
        assert!(s.alarms[0].targets.is_empty());
    }

    #[test]
    fn one_shot_fires_once_then_disables() {
        let mut s = store();
        s.handle(&json!({ "cmd": "alarm", "hour": 7, "minute": 30, "label": "wake" }), None);
        let emits = s.tick(at(7, 30));
        assert_eq!(emits.len(), 1);
        assert_eq!(emits[0].id, "alarm.fired");
        assert_eq!(emits[0].payload["time"], json!("07:30"));
        assert_eq!(emits[0].payload["to"], json!("everyone"));
        // The lastFired guard means a second tick in the same minute is a no-op…
        assert!(s.tick(at(7, 30)).is_empty());
        // …and a one-shot disarms itself.
        assert!(!s.alarms[0].enabled);
    }

    #[test]
    fn quiet_alarm_uses_the_other_signal_id() {
        let mut s = store();
        s.handle(&json!({ "cmd": "alarm", "hour": 9, "minute": 0, "quiet": true }), None);
        let emits = s.tick(at(9, 0));
        assert_eq!(emits[0].id, "alarm.quiet");
        assert_eq!(s.snapshot()["alarms"][0]["detail"], json!("Alarm, quiet"));
    }

    #[test]
    fn repeat_days_gate_the_fire_and_survive_it() {
        let mut s = store();
        let today = Local::now().weekday().number_from_sunday();
        let other = if today == 1 { 2 } else { 1 };
        s.handle(&json!({ "cmd": "alarm", "hour": 6, "minute": 0, "days": [other] }), None);
        assert!(s.tick(at(6, 0)).is_empty()); // wrong weekday
        s.handle(&json!({ "cmd": "edit", "id": "a1", "days": [today] }), None);
        assert_eq!(s.tick(at(6, 0)).len(), 1);
        assert!(s.alarms[0].enabled); // a repeating alarm stays armed
    }

    #[test]
    fn editing_re_arms_the_minute_guard() {
        let mut s = store();
        s.handle(&json!({ "cmd": "alarm", "hour": 5, "minute": 0, "days": [1,2,3,4,5,6,7] }), None);
        s.tick(at(5, 0));
        assert!(s.alarms[0].last_fired.is_some());
        s.handle(&json!({ "cmd": "edit", "id": "a1", "label": "renamed" }), None);
        assert!(s.alarms[0].last_fired.is_none());
        assert_eq!(s.alarms[0].label, "renamed");
        assert_eq!(s.tick(at(5, 0)).len(), 1); // rings again in the same minute
    }

    /// What the GUI's alarm sheet actually posts (`update` is its name for `edit`).
    #[test]
    fn the_sheet_round_trips() {
        let mut s = store();
        s.handle(
            &json!({ "cmd": "alarm", "when": "07:00", "label": "a", "note": "",
                     "days": [], "quiet": false, "targets": [] }),
            None,
        );
        assert!(s.alarms[0].wake);
        let (r, _) = s.handle(
            &json!({ "cmd": "update", "id": "a1", "when": "22:05", "label": "nightly",
                     "note": "run the backup", "days": [2,4,6], "quiet": true, "targets": ["1002"] }),
            None,
        );
        assert_eq!(r["ok"], json!(true));
        let a = &s.alarms[0];
        assert_eq!((a.hour, a.minute), (22, 5));
        assert!(!a.wake);
        assert_eq!(days::summary(&a.repeat_days), "Mon Wed Fri");
        assert_eq!(r["alarms"][0]["wakes"], json!("bob"));
        // The drum posts plain seconds in `dur`; clearing every pill means one-shot.
        let (r, _) = s.handle(&json!({ "cmd": "timer", "dur": "300", "label": "" }), None);
        assert_eq!(r["timers"][0]["remainingText"], json!("5:00"));
        s.handle(&json!({ "cmd": "update", "id": "a1", "days": [] }), None);
        assert_eq!(days::summary(&s.alarms[0].repeat_days), "Once");
    }

    #[test]
    fn edit_keeps_every_omitted_field() {
        let mut s = store();
        s.handle(
            &json!({ "cmd": "alarm", "when": "7:30", "label": "standup", "note": "n",
                     "repeat": "weekdays", "to": "alice", "quiet": true }),
            Some("1002".into()),
        );
        s.handle(&json!({ "cmd": "edit", "id": "a1", "when": "8:15" }), None);
        let a = &s.alarms[0];
        assert_eq!((a.hour, a.minute), (8, 15));
        assert_eq!(a.label, "standup");
        assert_eq!(a.note, "n");
        assert_eq!(days::summary(&a.repeat_days), "Weekdays");
        assert_eq!(a.targets, vec!["1001".to_string()]);
        assert!(!a.wake);
        assert_eq!(a.owner.as_deref(), Some("1002")); // ownership is NOT editable
    }

    #[test]
    fn toggle_and_enable_re_arm() {
        let mut s = store();
        s.handle(&json!({ "cmd": "alarm", "when": "7:30" }), None);
        s.alarms[0].last_fired = Some("x".into());
        s.handle(&json!({ "cmd": "toggle", "id": "a1" }), None);
        assert!(!s.alarms[0].enabled);
        assert!(s.alarms[0].last_fired.is_none());
        assert_eq!(s.snapshot()["alarms"][0]["nextText"], json!("off"));
        s.handle(&json!({ "cmd": "enable", "id": "a1", "on": true }), None);
        assert!(s.alarms[0].enabled);
    }

    #[test]
    fn timers_pause_resume_and_fire_to_their_owner() {
        let mut s = store();
        let (r, _) = s.handle(&json!({ "cmd": "timer", "dur": "1h30m", "label": "bake" }), Some("1001".into()));
        assert_eq!(r["timers"][0]["remainingText"], json!("1:30:00"));
        assert_eq!(r["timers"][0]["owner"], json!("alice"));
        s.handle(&json!({ "cmd": "pause", "id": "t1" }), None);
        assert!(!s.timers[0].is_running());
        assert_eq!(s.snapshot()["timers"][0]["endText"], json!("paused"));
        s.handle(&json!({ "cmd": "resume", "id": "t1" }), None);
        assert!(s.timers[0].is_running());
        // Expire it and check the signal.
        s.timers[0].end_at = Local::now().timestamp() - 1;
        let emits = s.tick(Local::now());
        assert_eq!(emits.len(), 1);
        assert_eq!(emits[0].id, "timer.done");
        assert_eq!(emits[0].target, vec!["1001".to_string()]);
        assert_eq!(emits[0].payload["seconds"], json!("5400"));
        assert_eq!(emits[0].payload["for"], json!("alice"));
        // The GUI drum sends plain seconds instead of a duration string.
        let (r, _) = s.handle(&json!({ "cmd": "timer", "seconds": 300 }), None);
        assert_eq!(r["timers"][1]["remainingText"], json!("5:00"));
    }

    #[test]
    fn sorts_by_time_then_id() {
        let mut s = store();
        for w in ["9:00", "7:30", "9:00"] {
            s.handle(&json!({ "cmd": "alarm", "when": w }), None);
        }
        let ids: Vec<&str> = s.alarms.iter().map(|a| a.id.as_str()).collect();
        assert_eq!(ids, ["a2", "a1", "a3"]);
    }

    #[test]
    fn decodes_a_swift_written_store_and_a_legacy_rust_one() {
        // Swift's shape: camelCase keys, ISO-8601 endAt, nextA/nextT.
        let swift = r#"{
          "alarms": [{ "id": "a4", "hour": 7, "minute": 30, "label": "standup", "note": "hi",
                       "repeatDays": [2,3,4,5,6], "enabled": true, "wakeAgent": true,
                       "ownerId": "1001", "lastFired": "202607291230" }],
          "timers": [{ "id": "t2", "label": "bake", "total": 600,
                       "endAt": "2026-07-29T11:30:00Z", "done": false }],
          "nextA": 5, "nextT": 3 }"#;
        let p: Persist = serde_json::from_str(swift).unwrap();
        assert_eq!(days::summary(&p.alarms[0].repeat_days), "Weekdays");
        // A stored alarm without `targets` falls back to its owner.
        assert_eq!(p.alarms[0].targets, vec!["1001".to_string()]);
        assert_eq!(p.timers[0].end_at, 1_785_324_600);
        assert_eq!((p.next_a, p.next_t), (5, 3));

        // The first Rust build's shape: `repeat` as a string, unix `end_at`, snake ids.
        let legacy = r#"{
          "alarms": [{ "id": "a1", "hour": 8, "minute": 0, "label": "x", "note": "",
                       "repeat": "daily", "enabled": true, "wake": false, "owner": null, "targets": [] }],
          "timers": [{ "id": "t1", "label": "", "total": 60, "end_at": 1785324600,
                       "paused": null, "done": false, "owner": null }],
          "next_alarm": 1, "next_timer": 1 }"#;
        let p: Persist = serde_json::from_str(legacy).unwrap();
        assert_eq!(days::summary(&p.alarms[0].repeat_days), "Every day");
        assert!(!p.alarms[0].wake);
        assert_eq!(p.timers[0].end_at, 1_785_324_600);

        // Round-trip: what we write is what Swift would write.
        let text = serde_json::to_string(&p).unwrap();
        assert!(text.contains(r#""repeatDays""#));
        assert!(text.contains(r#""endAt":"2026-07-29T11:30:00Z""#));
        assert!(text.contains(r#""nextA""#));
        serde_json::from_str::<Persist>(&text).unwrap();
    }

    /// A hand-edited (or older-build) clock.json used to index `SHORT[9]` and panic — in
    /// `snapshot`, i.e. on every command AND every 1-second tick, so the app crash-looped
    /// and only a manual edit of the file could stop it.
    #[test]
    fn an_out_of_range_repeat_day_is_dropped_not_indexed() {
        let bad = r#"{ "alarms": [{ "id": "a1", "hour": 7, "minute": 30,
                        "repeatDays": [0, 2, 9, 255] }], "timers": [] }"#;
        let p: Persist = serde_json::from_str(bad).unwrap();
        assert_eq!(p.alarms[0].repeat_days, [2].into_iter().collect::<BTreeSet<u32>>());
        assert_eq!(days::summary(&p.alarms[0].repeat_days), "Mon");
        // …and the projection that used to panic now runs.
        let mut s = store();
        s.alarms = p.alarms;
        assert_eq!(s.snapshot()["alarms"][0]["repeat"], json!("Mon"));
        // Belt and braces: even a set that somehow held a bad day only loses that day.
        assert_eq!(days::summary(&[9, 2].into_iter().collect()), "Mon");
    }

    /// `clock timer 9223372036854775807s` parsed cleanly and then overflowed
    /// `now + seconds`: a panic in debug, an instantly-"done" timer in release.
    #[test]
    fn an_absurd_duration_is_refused_instead_of_overflowing() {
        let mut s = store();
        let (r, _) = s.handle(&json!({ "cmd": "timer", "seconds": i64::MAX }), None);
        assert_eq!(r["ok"], json!(false));
        assert!(r["error"].as_str().unwrap().contains("365d"));
        assert!(s.timers.is_empty());
        assert_eq!(s.handle(&json!({ "cmd": "timer", "dur": "9223372036854775807s" }), None).0["ok"], json!(false));
        // The ceiling itself is still accepted.
        assert_eq!(s.handle(&json!({ "cmd": "timer", "seconds": MAX_TIMER_SECS }), None).0["ok"], json!(true));
    }

    /// `clock now` used to serialise and rewrite the whole store — on a verb the help
    /// text presents as the cheapest possible query.
    #[test]
    fn only_mutations_mark_the_store_dirty() {
        let mut s = store();
        s.take_dirty();
        for read in ["state", "list", "now"] {
            s.handle(&json!({ "cmd": read }), None);
            assert!(!s.take_dirty(), "`{read}` must not rewrite clock.json");
        }
        s.handle(&json!({ "cmd": "alarm", "when": "7:30" }), None);
        assert!(s.take_dirty(), "a mutation must persist");
        assert!(!s.take_dirty(), "and the flag clears once taken");
        // A firing tick persists too — lastFired and the one-shot disable must survive.
        s.handle(&json!({ "cmd": "alarm", "hour": 4, "minute": 5 }), None);
        s.take_dirty();
        assert!(s.tick(at(4, 5)).len() == 1 && s.take_dirty());
        assert!(s.tick(at(4, 5)).is_empty() && !s.take_dirty());
    }

    /// The snapshot carries the ordering the front end drops stale invoke replies by.
    #[test]
    fn every_snapshot_is_stamped_with_a_rising_rev() {
        let s = store();
        let a = s.snapshot()["rev"].as_u64().unwrap();
        let b = s.snapshot()["rev"].as_u64().unwrap();
        assert!(b > a && a > 0);
    }

    /// clappkit's AgentRow normalises Clatch's empty strings to `None`; the emitted JSON
    /// must not change shape for the webview, which types `backend` as a plain string.
    #[test]
    fn the_roster_projection_keeps_its_wire_shape() {
        let mut s = Store::default();
        s.set_agents(vec![
            AgentRow { id: "1001".into(), name: "alice".into(), ..Default::default() },
            AgentRow {
                id: "1002".into(),
                name: "bob".into(),
                backend: Some("claude-code".into()),
                model: Some("opus".into()),
                ..Default::default()
            },
        ]);
        let snap = s.snapshot();
        assert_eq!(snap["agents"][0]["backend"], json!("")); // never null
        assert_eq!(snap["agents"][0]["model"], Value::Null); // blank-filtered, not ""
        assert_eq!(snap["agents"][1]["backend"], json!("claude-code"));
        assert_eq!(snap["agents"][1]["model"], json!("opus"));
    }

    #[test]
    fn unknown_ids_are_refused() {
        let mut s = store();
        assert_eq!(s.handle(&json!({ "cmd": "cancel", "id": "a9" }), None).0["ok"], json!(false));
        assert_eq!(s.handle(&json!({ "cmd": "toggle", "id": "a9" }), None).0["ok"], json!(false));
        assert_eq!(s.handle(&json!({ "cmd": "pause", "id": "t9" }), None).0["ok"], json!(false));
        assert_eq!(s.handle(&json!({ "cmd": "alarm", "when": "nope" }), None).0["ok"], json!(false));
        assert_eq!(s.handle(&json!({ "cmd": "timer", "dur": "nope" }), None).0["ok"], json!(false));
        assert_eq!(s.handle(&json!({ "cmd": "wat" }), None).0["ok"], json!(false));
    }
}
