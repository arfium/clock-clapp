//! The shared clock state (the "daemon"): alarms, timers, and the 1-second scheduler
//! that turns a due alarm/timer into a Clatch signal. The GUI (Tauri commands) and the
//! CLI (clappkit IPC) mutate it through the SAME `handle` method, so the two surfaces
//! never drift — "share state, not screens". Portable Rust; no platform code.

use chrono::{Datelike, Local, TimeZone, Timelike};
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};

/// A signal the scheduler wants Clatch to deliver — drained by the task that owns the
/// control-pipe `Client` (the Store never touches the pipe itself).
#[derive(Debug, Clone)]
pub struct Emit {
    pub id: String,          // "alarm.fired" | "alarm.quiet" | "timer.done" | "alarm.set"
    pub target: Vec<String>, // agent ids ([] = broadcast)
    pub payload: Value,
}

#[derive(Serialize, Deserialize, Clone, Copy, PartialEq)]
#[serde(rename_all = "lowercase")]
pub enum Repeat {
    Once,
    Daily,
    Weekdays,
    Weekends,
}

impl Repeat {
    /// Is this repeat due on `weekday` (0 = Mon … 6 = Sun)?
    fn due(self, weekday: u8) -> bool {
        match self {
            Repeat::Once | Repeat::Daily => true,
            Repeat::Weekdays => weekday < 5,
            Repeat::Weekends => weekday >= 5,
        }
    }
    fn label(self) -> &'static str {
        match self {
            Repeat::Once => "Once",
            Repeat::Daily => "Every day",
            Repeat::Weekdays => "Weekdays",
            Repeat::Weekends => "Weekends",
        }
    }
    fn parse(s: &str) -> Repeat {
        match s.to_ascii_lowercase().as_str() {
            "daily" | "everyday" => Repeat::Daily,
            "weekdays" => Repeat::Weekdays,
            "weekends" => Repeat::Weekends,
            _ => Repeat::Once,
        }
    }
}

#[derive(Serialize, Deserialize, Clone)]
pub struct Alarm {
    pub id: String,
    pub hour: u32,
    pub minute: u32,
    pub label: String,
    pub note: String,        // the prompt delivered when it wakes the agent
    pub repeat: Repeat,
    pub enabled: bool,
    pub wake: bool,          // true → alarm.fired (run); false → alarm.quiet (context)
    pub owner: Option<String>,   // agent id that set it via CLI (None = human/GUI)
    pub targets: Vec<String>,    // agent ids to wake ([] = everyone)
}

#[derive(Serialize, Deserialize, Clone)]
pub struct Timer {
    pub id: String,
    pub label: String,
    pub total: i64,          // seconds
    pub end_at: i64,         // unix seconds deadline (while running)
    pub paused: Option<i64>, // Some(remaining secs) when paused
    pub done: bool,
    pub owner: Option<String>,
}

impl Timer {
    fn remaining(&self, now: i64) -> i64 {
        match self.paused {
            Some(r) => r,
            None => (self.end_at - now).max(0),
        }
    }
}

/// One bound agent, mirrored from the control pipe's roster (for id ↔ name display).
#[derive(Clone, Default)]
pub struct AgentRow {
    pub id: String,
    pub name: String,
}

#[derive(Default)]
pub struct Store {
    pub alarms: Vec<Alarm>,
    pub timers: Vec<Timer>,
    next_alarm: u32,
    next_timer: u32,
    agents: Vec<AgentRow>,
    last_minute: Option<(u32, u32)>, // fire alarms once per (hour, minute)
}

#[derive(Serialize, Deserialize, Default)]
struct Persist {
    alarms: Vec<Alarm>,
    timers: Vec<Timer>,
    next_alarm: u32,
    next_timer: u32,
}

impl Store {
    // MARK: roster (id ↔ name)

    pub fn set_agents(&mut self, agents: Vec<AgentRow>) {
        self.agents = agents;
    }
    fn name_for(&self, id: &str) -> Option<String> {
        self.agents.iter().find(|a| a.id == id).map(|a| a.name.clone())
    }
    fn ids_for(&self, names: &str) -> Vec<String> {
        // "everyone" → [] (broadcast); "a,b" → the ids of a and b (unknown names kept raw)
        if names.eq_ignore_ascii_case("everyone") || names.is_empty() {
            return vec![];
        }
        names
            .split(',')
            .map(|n| n.trim())
            .filter(|n| !n.is_empty())
            .map(|n| {
                self.agents
                    .iter()
                    .find(|a| a.name.eq_ignore_ascii_case(n))
                    .map(|a| a.id.clone())
                    .unwrap_or_else(|| n.to_string())
            })
            .collect()
    }

    // MARK: scheduler

    /// One tick (call ~every second). Emits due alarm/timer signals.
    pub fn tick(&mut self, now: chrono::DateTime<Local>) -> Vec<Emit> {
        let mut emits = Vec::new();
        let (h, m) = (now.hour(), now.minute());
        let weekday = now.weekday().num_days_from_monday() as u8;
        if self.last_minute != Some((h, m)) {
            self.last_minute = Some((h, m));
            for a in &mut self.alarms {
                if a.enabled && a.hour == h && a.minute == m && a.repeat.due(weekday) {
                    let id = if a.wake { "alarm.fired" } else { "alarm.quiet" };
                    let mut payload = json!({ "label": a.label });
                    if !a.note.is_empty() {
                        payload["note"] = json!(a.note);
                    }
                    emits.push(Emit { id: id.into(), target: a.targets.clone(), payload });
                    if a.repeat == Repeat::Once {
                        a.enabled = false;
                    }
                }
            }
        }
        let now_s = now.timestamp();
        for t in &mut self.timers {
            if !t.done && t.paused.is_none() && now_s >= t.end_at {
                t.done = true;
                emits.push(Emit {
                    id: "timer.done".into(),
                    target: t.owner.clone().into_iter().collect(),
                    payload: json!({ "label": t.label }),
                });
            }
        }
        emits
    }

    // MARK: the one command handler (GUI + CLI both call this)

    /// Apply a command and return `(response, signals-to-emit)`. `cmd` is a JSON object
    /// `{ "cmd": "...", ... }`; `caller` is the CLI caller's agent id (None = GUI/human).
    pub fn handle(&mut self, req: &Value, caller: Option<String>) -> (Value, Vec<Emit>) {
        let cmd = req.get("cmd").and_then(Value::as_str).unwrap_or("");
        let mut emits = Vec::new();
        let resp = match cmd {
            "state" => self.snapshot(),
            "alarm" => {
                let when = req.get("when").and_then(Value::as_str).unwrap_or("");
                let (hour, minute) = match parse_hhmm(when) {
                    Some(v) => v,
                    None => return (err("bad time — use HH:MM (e.g. 07:30)"), emits),
                };
                self.next_alarm += 1;
                let id = format!("a{}", self.next_alarm);
                let targets = self.ids_for(req.get("to").and_then(Value::as_str).unwrap_or(""));
                let alarm = Alarm {
                    id: id.clone(),
                    hour,
                    minute,
                    label: req.get("label").and_then(Value::as_str).unwrap_or("").to_string(),
                    note: req.get("note").and_then(Value::as_str).unwrap_or("").to_string(),
                    repeat: Repeat::parse(req.get("repeat").and_then(Value::as_str).unwrap_or("once")),
                    enabled: true,
                    wake: !req.get("quiet").and_then(Value::as_bool).unwrap_or(false),
                    owner: caller.clone(),
                    targets,
                };
                // A human (GUI) add tells agents about it; an agent's own add is silent.
                if caller.is_none() {
                    emits.push(Emit {
                        id: "alarm.set".into(),
                        target: vec![],
                        payload: json!({ "label": alarm.label, "at": format!("{hour:02}:{minute:02}") }),
                    });
                }
                self.alarms.push(alarm);
                self.snapshot()
            }
            "timer" => {
                let secs = parse_dur(req.get("dur").and_then(Value::as_str).unwrap_or(""));
                if secs <= 0 {
                    return (err("bad duration — use e.g. 10m, 1h30m, 90s"), emits);
                }
                self.next_timer += 1;
                let id = format!("t{}", self.next_timer);
                self.timers.push(Timer {
                    id,
                    label: req.get("label").and_then(Value::as_str).unwrap_or("").to_string(),
                    total: secs,
                    end_at: Local::now().timestamp() + secs,
                    paused: None,
                    done: false,
                    owner: caller.clone(),
                });
                self.snapshot()
            }
            "cancel" => {
                let id = req.get("id").and_then(Value::as_str).unwrap_or("");
                let before = self.alarms.len() + self.timers.len();
                self.alarms.retain(|a| a.id != id);
                self.timers.retain(|t| t.id != id);
                if self.alarms.len() + self.timers.len() < before {
                    self.snapshot()
                } else {
                    err(&format!("no alarm or timer with id {id}"))
                }
            }
            "toggle" => {
                let id = req.get("id").and_then(Value::as_str).unwrap_or("");
                if let Some(a) = self.alarms.iter_mut().find(|a| a.id == id) {
                    a.enabled = !a.enabled;
                    self.snapshot()
                } else {
                    err(&format!("no alarm with id {id}"))
                }
            }
            other => err(&format!("unknown command: {other}")),
        };
        (resp, emits)
    }

    // MARK: projection for GUI + CLI

    pub fn snapshot(&self) -> Value {
        let now = Local::now().timestamp();
        let alarms: Vec<Value> = self
            .alarms
            .iter()
            .map(|a| {
                json!({
                    "id": a.id,
                    "time": format!("{:02}:{:02}", a.hour, a.minute),
                    "label": a.label,
                    "note": a.note,
                    "repeat": a.repeat.label(),
                    "enabled": a.enabled,
                    "wake": a.wake,
                    "owner": a.owner.as_deref().and_then(|id| self.name_for(id)),
                    "wakes": self.wakes_text(&a.targets),
                })
            })
            .collect();
        let timers: Vec<Value> = self
            .timers
            .iter()
            .map(|t| {
                let rem = t.remaining(now);
                json!({
                    "id": t.id,
                    "label": t.label,
                    "remaining": rem,
                    "remainingText": fmt_dur(rem),
                    "total": t.total,
                    "running": t.paused.is_none() && !t.done,
                    "done": t.done,
                    "owner": t.owner.as_deref().and_then(|id| self.name_for(id)),
                })
            })
            .collect();
        json!({ "ok": true, "alarms": alarms, "timers": timers })
    }

    fn wakes_text(&self, targets: &[String]) -> String {
        if targets.is_empty() {
            "everyone".into()
        } else {
            targets
                .iter()
                .map(|id| self.name_for(id).unwrap_or_else(|| id.clone()))
                .collect::<Vec<_>>()
                .join(", ")
        }
    }

    // MARK: persistence (CLATCH_DATA_DIR, falling back to ~/.clock)

    pub fn path() -> std::path::PathBuf {
        let dir = std::env::var("CLATCH_DATA_DIR").ok().unwrap_or_else(|| {
            let home = std::env::var("HOME").unwrap_or_else(|_| ".".into());
            format!("{home}/.clock")
        });
        let _ = std::fs::create_dir_all(&dir);
        std::path::Path::new(&dir).join("clock.json")
    }

    pub fn load() -> Store {
        let mut store = Store::default();
        if let Ok(text) = std::fs::read_to_string(Store::path()) {
            if let Ok(p) = serde_json::from_str::<Persist>(&text) {
                store.alarms = p.alarms;
                store.timers = p.timers;
                store.next_alarm = p.next_alarm;
                store.next_timer = p.next_timer;
            }
        }
        store
    }

    pub fn save(&self) {
        let p = Persist {
            alarms: self.alarms.clone(),
            timers: self.timers.clone(),
            next_alarm: self.next_alarm,
            next_timer: self.next_timer,
        };
        if let Ok(text) = serde_json::to_string_pretty(&p) {
            let path = Store::path();
            let tmp = path.with_extension("json.tmp");
            if std::fs::write(&tmp, text).is_ok() {
                let _ = std::fs::rename(&tmp, &path); // atomic replace (valid on Windows too)
            }
        }
    }
}

fn err(msg: &str) -> Value {
    json!({ "ok": false, "error": msg })
}

/// Parse "HH:MM" / "7:30" (also tolerates "7:30am"/"pm").
fn parse_hhmm(s: &str) -> Option<(u32, u32)> {
    let s = s.trim().to_ascii_lowercase();
    let (body, ampm) = if let Some(b) = s.strip_suffix("am") {
        (b.trim(), Some(false))
    } else if let Some(b) = s.strip_suffix("pm") {
        (b.trim(), Some(true))
    } else {
        (s.as_str(), None)
    };
    let (h, m) = body.split_once(':')?;
    let mut hour: u32 = h.trim().parse().ok()?;
    let minute: u32 = m.trim().parse().ok()?;
    if let Some(pm) = ampm {
        hour %= 12;
        if pm {
            hour += 12;
        }
    }
    if hour < 24 && minute < 60 {
        Some((hour, minute))
    } else {
        None
    }
}

/// Parse "10m", "1h30m", "90s", "45" (bare = seconds) → total seconds.
fn parse_dur(s: &str) -> i64 {
    let s = s.trim().to_ascii_lowercase();
    if let Ok(n) = s.parse::<i64>() {
        return n;
    }
    let mut total = 0i64;
    let mut num = String::new();
    for c in s.chars() {
        if c.is_ascii_digit() {
            num.push(c);
        } else {
            let n: i64 = num.parse().unwrap_or(0);
            num.clear();
            total += match c {
                'h' => n * 3600,
                'm' => n * 60,
                's' => n,
                _ => 0,
            };
        }
    }
    total
}

fn fmt_dur(secs: i64) -> String {
    let s = secs.max(0);
    let (h, m, sec) = (s / 3600, (s % 3600) / 60, s % 60);
    if h > 0 {
        format!("{h}:{m:02}:{sec:02}")
    } else {
        format!("{m}:{sec:02}")
    }
}

// A tiny helper the app uses to turn a unix-seconds instant back into Local (kept here
// so the timestamp math lives with the model).
#[allow(dead_code)]
pub fn local_from_unix(secs: i64) -> chrono::DateTime<Local> {
    Local.timestamp_opt(secs, 0).single().unwrap_or_else(Local::now)
}
