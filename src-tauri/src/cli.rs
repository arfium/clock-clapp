//! The agent's CLI: `clock <verb> …` connects to the running app over clappkit's IPC
//! and prints the result. `clock --help` is the agent's ONLY manual.

use clappkit::ipc;
use serde_json::{json, Value};
use std::collections::HashMap;

const CLI: &str = "clock";

const HELP: &str = "\
clock — a shared clock for you and your human: alarms and timers. The human drives a
window; you drive this CLI on the same live state. Set timed work and Clatch wakes you
when it comes due (an `alarm.fired` / `timer.done` run signal — the alarm's --note is
the prompt for that turn).

usage:
  clock alarm <HH:MM> \"<label>\" [--note \"…\"] [--repeat daily|weekdays|weekends]
                                 [--to alice,bob|everyone] [--quiet]
  clock timer <dur> \"<label>\"      a countdown — 10m, 1h30m, 90s, 45 (=secs)
  clock list                        every alarm and timer, with who set/wakes each
  clock cancel <id>                 cancel by id (aN alarm · tN timer)
  clock toggle <id>                 enable/disable an alarm
  clock help                        this manual

You do not poll — an alarm/timer you set wakes exactly YOU when due (Clatch injected
your id). --to chooses other agents; --quiet notifies without starting a turn.";

pub async fn run(args: Vec<String>) -> ! {
    let verb = args.first().map(String::as_str).unwrap_or("help");
    let rest: Vec<String> = args.iter().skip(1).cloned().collect();
    // Forward CLATCH_AGENT_ID so what you set is owned by (and wakes) you.
    let agent = std::env::var("CLATCH_AGENT_ID").ok().filter(|s| !s.is_empty());

    let req: Value = match verb {
        "help" | "-h" | "--help" => {
            println!("{HELP}");
            std::process::exit(0);
        }
        "list" | "state" => json!({ "cmd": "state" }),
        "alarm" => {
            let (flags, pos) = split_flags(&rest);
            let mut r = json!({
                "cmd": "alarm",
                "when": pos.first().cloned().unwrap_or_default(),
                "label": pos.get(1).cloned().unwrap_or_default(),
            });
            if let Some(v) = flags.get("note") { r["note"] = json!(v); }
            if let Some(v) = flags.get("repeat") { r["repeat"] = json!(v); }
            if let Some(v) = flags.get("to") { r["to"] = json!(v); }
            if flags.contains_key("quiet") { r["quiet"] = json!(true); }
            if let Some(a) = &agent { r["agent"] = json!(a); }
            r
        }
        "timer" => {
            let (_f, pos) = split_flags(&rest);
            let mut r = json!({
                "cmd": "timer",
                "dur": pos.first().cloned().unwrap_or_default(),
                "label": pos.get(1).cloned().unwrap_or_default(),
            });
            if let Some(a) = &agent { r["agent"] = json!(a); }
            r
        }
        "cancel" => json!({ "cmd": "cancel", "id": rest.first().cloned().unwrap_or_default() }),
        "toggle" => json!({ "cmd": "toggle", "id": rest.first().cloned().unwrap_or_default() }),
        other => {
            eprintln!("clock: unknown command '{other}' (try: clock help)");
            std::process::exit(1);
        }
    };

    match ipc::request(CLI, &req).await {
        Ok(v) => {
            print_result(&v);
            std::process::exit(0);
        }
        Err(e) => {
            eprintln!("{e}");
            std::process::exit(1);
        }
    }
}

/// `--key value` / `--flag` (only `quiet` is a bare flag) → (flags, positionals).
fn split_flags(rest: &[String]) -> (HashMap<String, String>, Vec<String>) {
    let mut flags = HashMap::new();
    let mut pos = Vec::new();
    let mut i = 0;
    while i < rest.len() {
        if let Some(k) = rest[i].strip_prefix("--") {
            if k == "quiet" {
                flags.insert(k.to_string(), "true".to_string());
                i += 1;
            } else if i + 1 < rest.len() {
                flags.insert(k.to_string(), rest[i + 1].clone());
                i += 2;
            } else {
                flags.insert(k.to_string(), String::new());
                i += 1;
            }
        } else {
            pos.push(rest[i].clone());
            i += 1;
        }
    }
    (flags, pos)
}

fn print_result(v: &Value) {
    if v.get("ok").and_then(Value::as_bool) == Some(false) {
        eprintln!("clock: {}", v.get("error").and_then(Value::as_str).unwrap_or("failed"));
        std::process::exit(1);
    }
    let alarms = v.get("alarms").and_then(Value::as_array).cloned().unwrap_or_default();
    let timers = v.get("timers").and_then(Value::as_array).cloned().unwrap_or_default();
    if alarms.is_empty() && timers.is_empty() {
        println!("(no alarms or timers)");
        return;
    }
    for a in &alarms {
        let g = |k: &str| a.get(k).and_then(Value::as_str).unwrap_or("");
        let mut line = format!("{}  {}  {}", g("id"), g("time"), g("label"));
        if a.get("enabled").and_then(Value::as_bool) == Some(false) {
            line.push_str("  [off]");
        }
        let repeat = g("repeat");
        if !repeat.is_empty() && repeat != "Once" {
            line.push_str(&format!("  ({repeat})"));
        }
        line.push_str(&format!("  → {}", g("wakes")));
        if let Some(owner) = a.get("owner").and_then(Value::as_str) {
            line.push_str(&format!("  by {owner}"));
        }
        if !g("note").is_empty() {
            line.push_str(&format!("  note: {}", g("note")));
        }
        println!("{line}");
    }
    for t in &timers {
        let g = |k: &str| t.get(k).and_then(Value::as_str).unwrap_or("");
        println!("{}  {}  {}", g("id"), g("remainingText"), g("label"));
    }
}
