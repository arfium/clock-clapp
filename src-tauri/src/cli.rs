//! The agent's CLI: `clock <verb> …` connects to the running app over clappkit's IPC
//! and prints the result. `clock --help` is the agent's ONLY manual.

use clappkit::ipc;
use serde_json::{json, Value};
use std::collections::HashMap;

const CLI: &str = "clock";

const HELP: &str = r#"clock — a shared alarm clock for you and your agent.
You (the agent) schedule your own alarms and timers; the human sets them in the GUI.
By default an alarm/timer wakes the agent who set it — but who an alarm wakes is
selectable (in the GUI, or with `--to`): when it fires the chosen agent(s) get a signal
(`alarm.fired` / `timer.done`, type run) that wakes them for that turn.

usage:
  clock now                          print the current time
  clock list                         list all alarms and timers (→ shows who each wakes)
  clock alarm <time> "<label>"       set an alarm at a wall-clock time
      --note "<text>"                what to do when it fires — this becomes YOUR
                                     PROMPT for the turn the alarm wakes
      --to <agents>                  who to wake: everyone | alice | alice,bob
                                     (default: just you; the human picks in the GUI)
      --repeat <days>                daily | weekdays | weekends | mon,wed,fri
      --quiet                        fire as context (do NOT wake you → alarm.quiet)
  clock edit <id> [<time>]           change an alarm; omitted flags keep their value
      --time · --label · --note · --repeat · --quiet · --wake · --to
  clock timer <dur> "<label>"        start a countdown (fires timer.done when it ends)
  clock cancel <id>                  remove an alarm (aN) or timer (tN)
  clock toggle <id>                  enable / disable an alarm
  clock pause <id> / resume <id>     pause / resume a timer
  clock show                         open the window (same as `focus`)
  clock hide                         send it back to the background
  clock close                        quit the app — this is what stops the alarms

clock keeps time with or without a window. `clock app --background` starts it with no
window and no Dock icon; closing the window just backgrounds it again. Set an alarm
without taking over the screen, and `clock show` only when you want to be seen.

<time>  7:30 · 07:30 · 7:30am · 19:30        <dur>  10m · 1h30m · 90s · 45s
`clock set <when> …` is a shorthand: a clock time makes an alarm, a duration a timer.

The note is the whole point of a wake alarm: when it fires you get a fresh turn with
no memory of setting it, and the note is the only context that survives. Write the
full instruction, not a reminder to yourself to remember something.
  clock alarm 9:00 "standup" --note "post yesterday's diff summary to #eng""#;

/// Every usage error the agent can hit reads the same: `clock: <what to do instead>`.
fn fail(msg: &str) -> ! {
    eprintln!("clock: {msg}");
    std::process::exit(1);
}

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
        // Status + window verbs take no arguments. `close` is the quit command — the one
        // thing that stops the alarms; `hide`/`show` only move the window.
        "now" | "list" | "state" | "focus" | "show" | "hide" | "close" => {
            if !rest.is_empty() {
                fail(&format!("usage: clock {verb}"));
            }
            let cmd = match verb {
                "list" => "state",
                "close" => "quit",
                v => v,
            };
            json!({ "cmd": cmd })
        }
        // `set` is the smart alias: a clock time makes an alarm, a duration a timer —
        // the store decides, so all three share one argument shape.
        "alarm" | "set" | "timer" => {
            let (flags, pos) = split_flags(&rest);
            let Some(when) = pos.first().cloned() else {
                fail(&format!("usage: clock {verb} <when> [\"<label>\"] …"));
            };
            // `--label` wins; otherwise every remaining positional joins into the label.
            let label = flags.get("label").cloned().unwrap_or_else(|| pos[1..].join(" "));
            let mut r = json!({ "cmd": verb, "label": label });
            r[if verb == "timer" { "dur" } else { "when" }] = json!(when);
            if let Some(v) = flags.get("note") { r["note"] = json!(v); }
            if let Some(v) = flags.get("repeat").or_else(|| flags.get("days")) { r["repeat"] = json!(v); }
            if let Some(v) = flags.get("to").or_else(|| flags.get("agents")) { r["to"] = json!(v); }
            if flags.contains_key("quiet") { r["quiet"] = json!(true); }
            if flags.contains_key("wake") { r["quiet"] = json!(false); }
            if let Some(a) = &agent { r["agent"] = json!(a); }
            r
        }
        // Partial update: every flag you omit keeps its current value. Ownership is not
        // editable — whoever set the alarm stays the one it wakes.
        "edit" => {
            let (flags, pos) = split_flags(&rest);
            let Some(id) = pos.first().cloned() else {
                fail("usage: clock edit <id> [--time 8:00] […]");
            };
            let mut r = json!({ "cmd": "edit", "id": id });
            match flags.get("time").or_else(|| flags.get("when")) {
                Some(v) => r["when"] = json!(v),
                // a bare second positional is the new time: `clock edit a1 8:15`
                None => if let Some(v) = pos.get(1) { r["when"] = json!(v); },
            }
            if let Some(v) = flags.get("label") { r["label"] = json!(v); }
            if let Some(v) = flags.get("note") { r["note"] = json!(v); }
            if let Some(v) = flags.get("repeat").or_else(|| flags.get("days")) { r["repeat"] = json!(v); }
            if let Some(v) = flags.get("to").or_else(|| flags.get("agents")) { r["to"] = json!(v); }
            if flags.contains_key("quiet") { r["quiet"] = json!(true); }
            if flags.contains_key("wake") { r["quiet"] = json!(false); }
            if let Some(a) = &agent { r["agent"] = json!(a); }
            r
        }
        "cancel" | "toggle" | "pause" | "resume" => {
            if rest.len() != 1 {
                fail(&format!("usage: clock {verb} <id>"));
            }
            json!({ "cmd": verb, "id": rest[0] })
        }
        other => fail(&format!("unknown command: {other} (try: clock help)")),
    };

    match ipc::request(CLI, &req).await {
        Ok(v) => {
            if v.get("ok").and_then(Value::as_bool) == Some(false) {
                fail(v.get("error").and_then(Value::as_str).unwrap_or("rejected"));
            }
            match verb {
                "now" => println!("{}", v.get("nowText").and_then(Value::as_str).unwrap_or("?")),
                // The window verbs answer with a line, not a listing.
                "show" | "focus" | "hide" | "close" => {
                    println!("{}", v.get("message").and_then(Value::as_str).unwrap_or("ok"))
                }
                _ => print_result(&v),
            }
            std::process::exit(0);
        }
        Err(e) => {
            eprintln!("{e}");
            std::process::exit(1);
        }
    }
}

/// `--key value` / `--flag` (`quiet` and `wake` are the bare flags) → (flags, positionals).
fn split_flags(rest: &[String]) -> (HashMap<String, String>, Vec<String>) {
    let mut flags = HashMap::new();
    let mut pos = Vec::new();
    let mut i = 0;
    while i < rest.len() {
        if let Some(k) = rest[i].strip_prefix("--") {
            if k == "quiet" || k == "wake" {
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
        if a.get("wake").and_then(Value::as_bool) == Some(false) {
            line.push_str("  (quiet)");
        }
        line.push_str(&format!("  → {}", g("wakes")));
        if let Some(owner) = a.get("owner").and_then(Value::as_str) {
            line.push_str(&format!("  by {owner}"));
        }
        let next = g("nextText");
        if !next.is_empty() && next != "off" {
            line.push_str(&format!("  next {next}"));
        }
        // The note is the payload of a wake alarm, so `list` shows it in full —
        // truncating would hide the very instruction the agent is meant to act on.
        if !g("note").is_empty() {
            line.push_str(&format!("  note: {}", g("note")));
        }
        println!("{line}");
    }
    for t in &timers {
        let g = |k: &str| t.get(k).and_then(Value::as_str).unwrap_or("");
        let mut line = format!("{}  {}  {}", g("id"), g("remainingText"), g("label"));
        if !g("endText").is_empty() {
            line.push_str(&format!("  [{}]", g("endText")));
        }
        if let Some(owner) = t.get("owner").and_then(Value::as_str) {
            line.push_str(&format!("  by {owner}"));
        }
        println!("{line}");
    }
}
