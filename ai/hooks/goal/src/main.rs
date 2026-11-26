//! A goal for one Claude Code session: its Stop hook, and the `claude-goal` CLI.
//!
//! Claude Code's own /goal is a session Stop hook, so it refuses to run under
//! the managed-only hook policy (ai/hooks/default.nix). This is its managed
//! replacement. It is inert unless a goal was armed for the exact session that
//! is stopping, and every doubt resolves to "let the session stop":
//!
//!   hook               Stop handler. Prints one `{"decision":"block"}` only
//!                      when this session has an armed, unexpired goal under
//!                      its continuation cap, nothing is scheduled to wake the
//!                      session, and the new count was saved first.
//!   arm [--hours N]    Arm this session's goal; the condition is read on stdin.
//!   status             Show this session's goal.
//!   met EVIDENCE       The condition holds: record the evidence, disarm.
//!   clear REASON       Disarm without meeting it (owner's cancel, dead end).
//!
//! The CLI finds its session through CLAUDE_CODE_SESSION_ID, which Claude Code
//! sets for every command it runs; the hook reads `session_id` from its input.

use serde_json::{json, Value};
use std::fs::{self, DirBuilder, OpenOptions};
use std::io::{Read, Write};
use std::os::unix::fs::DirBuilderExt;
use std::path::{Path, PathBuf};
use std::process::exit;
use std::time::{SystemTime, UNIX_EPOCH};

const DEFAULT_HOURS: f64 = 24.0;
const MAX_HOURS: f64 = 24.0 * 7.0;
/// Forced continuations per armed goal. Claude Code separately ends a chain of
/// eight blocks that contains no tool call (CLAUDE_CODE_STOP_HOOK_BLOCK_CAP).
const MAX_CONTINUATIONS: i64 = 200;
const MAX_CONDITION: usize = 4000;
/// The supervisor forwards a decision only as one atomic pipe write (macOS
/// PIPE_BUF is 512 bytes), so the whole JSON line must stay under it.
const MAX_OUTPUT: usize = 500;

struct Goal {
    condition: String,
    armed: f64,
    deadline: f64,
    continuations: i64,
}

fn now() -> f64 {
    SystemTime::now().duration_since(UNIX_EPOCH).map(|d| d.as_secs_f64()).unwrap_or(0.0)
}

/// UTC "YYYY-MM-DD HH:MM" without a date library (days-to-civil, Howard Hinnant).
fn utc(seconds: f64) -> String {
    let seconds = seconds as i64;
    let (days, rest) = (seconds.div_euclid(86_400), seconds.rem_euclid(86_400));
    let z = days + 719_468;
    let era = z.div_euclid(146_097);
    let doe = z - era * 146_097;
    let yoe = (doe - doe / 1460 + doe / 36_524 - doe / 146_096) / 365;
    let doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
    let mp = (5 * doy + 2) / 153;
    let day = doy - (153 * mp + 2) / 5 + 1;
    let month = if mp < 10 { mp + 3 } else { mp - 9 };
    let year = yoe + era * 400 + i64::from(month <= 2);
    format!("{year:04}-{month:02}-{day:02} {:02}:{:02} UTC", rest / 3600, rest % 3600 / 60)
}

fn state_directory() -> Option<PathBuf> {
    let base = match std::env::var("XDG_STATE_HOME") {
        Ok(value) if !value.is_empty() => PathBuf::from(value),
        _ => PathBuf::from(std::env::var("HOME").ok().filter(|h| !h.is_empty())?).join(".local/state"),
    };
    base.is_absolute().then(|| base.join("claude-goals"))
}

fn valid_session(session: &str) -> bool {
    let mut chars = session.chars();
    session.len() <= 128
        && chars.next().is_some_and(|c| c.is_ascii_alphanumeric())
        && chars.all(|c| c.is_ascii_alphanumeric() || c == '_' || c == '-')
}

fn goal_path(directory: &Path, session: &str) -> Option<PathBuf> {
    valid_session(session).then(|| directory.join(format!("{session}.json")))
}

fn read_goal(path: &Path) -> Option<Goal> {
    let value: Value = serde_json::from_str(&fs::read_to_string(path).ok()?).ok()?;
    let condition = value.get("condition")?.as_str()?.to_string();
    if condition.trim().is_empty() {
        return None;
    }
    Some(Goal {
        condition,
        armed: value.get("armed").and_then(Value::as_f64).unwrap_or(0.0),
        deadline: value.get("deadline")?.as_f64()?,
        continuations: value.get("continuations")?.as_i64()?,
    })
}

fn write_atomically(path: &Path, goal: &Goal) -> std::io::Result<()> {
    let directory = path.parent().expect("goal path has a parent");
    DirBuilder::new().recursive(true).mode(0o700).create(directory)?;
    let temporary = directory.join(format!(".goal-{}-{}", std::process::id(), now().to_bits()));
    let body = json!({
        "condition": goal.condition, "armed": goal.armed,
        "deadline": goal.deadline, "continuations": goal.continuations,
    });
    let result = (|| {
        let mut file = OpenOptions::new().write(true).create_new(true).open(&temporary)?;
        file.write_all(body.to_string().as_bytes())?;
        file.sync_all()?;
        fs::rename(&temporary, path)
    })();
    if result.is_err() {
        let _ = fs::remove_file(&temporary);
    }
    result
}

fn log(directory: &Path, session: &str, event: &str, detail: Value) {
    let mut entry = json!({"at": utc(now()), "session": session, "event": event});
    if let (Some(entry), Value::Object(detail)) = (entry.as_object_mut(), detail) {
        entry.extend(detail);
    }
    if let Ok(mut file) = OpenOptions::new().create(true).append(true).open(directory.join("log.jsonl")) {
        let _ = writeln!(file, "{entry}");
    }
}

fn block_line(goal: &Goal, count: i64) -> Option<String> {
    let condition = goal.condition.split_whitespace().collect::<Vec<_>>().join(" ");
    let total = condition.chars().count();
    // Shorten a long condition to fit; `claude-goal status` shows all of it.
    let mut keep = total as i64;
    while keep >= 0 {
        let shown = if keep as usize == total {
            condition.clone()
        } else {
            condition.chars().take(keep as usize).collect::<String>().trim_end().to_string() + "…"
        };
        let reason = format!(
            "Goal not met yet (continuation {count}/{MAX_CONTINUATIONS}, until {}): {shown} -- \
             Keep working toward it. When it holds, verify it and run `claude-goal met EVIDENCE`; \
             at a real dead end run `claude-goal clear REASON`. To wait on something, start a \
             background command, Monitor or CronCreate.",
            utc(goal.deadline)
        );
        let line = json!({"decision": "block", "reason": reason}).to_string();
        if line.len() <= MAX_OUTPUT {
            return Some(line);
        }
        keep -= 20;
    }
    None
}

/// The line to print, or None to let the session stop.
fn hook() -> Option<String> {
    let mut input = Vec::new();
    std::io::stdin().read_to_end(&mut input).ok()?;
    let event: Value = serde_json::from_slice(&input).ok()?;
    if event.get("hook_event_name")?.as_str()? != "Stop" {
        return None;
    }
    let directory = state_directory()?;
    let session = event.get("session_id")?.as_str()?;
    let path = goal_path(&directory, session)?;
    let goal = read_goal(&path)?;
    let expired = now() >= goal.deadline;
    if expired || goal.continuations >= MAX_CONTINUATIONS {
        fs::remove_file(&path).ok()?;
        let event = if expired { "expired" } else { "capped" };
        log(&directory, session, event, json!({"continuations": goal.continuations}));
        return None;
    }
    // Something is scheduled to wake this session: let it idle until then
    // rather than forcing a busy wait.
    let pending = |key: &str| event.get(key).and_then(Value::as_array).is_some_and(|a| !a.is_empty());
    if pending("background_tasks") || pending("session_crons") {
        return None;
    }
    let count = goal.continuations + 1;
    let line = block_line(&goal, count)?;
    // Count first: a block that could not be recorded is never sent.
    write_atomically(&path, &Goal { continuations: count, ..goal }).ok()?;
    log(&directory, session, "continued", json!({"continuations": count}));
    Some(line)
}

fn fail(message: &str) -> ! {
    eprintln!("claude-goal: {message}");
    exit(1)
}

fn cli(arguments: &[String]) {
    let directory = state_directory().unwrap_or_else(|| fail("no state directory (HOME unset)"));
    let session = std::env::var("CLAUDE_CODE_SESSION_ID").unwrap_or_default();
    let path = goal_path(&directory, &session)
        .unwrap_or_else(|| fail("run this from a Claude Code session (CLAUDE_CODE_SESSION_ID unset or invalid)"));
    let arguments: Vec<&str> = arguments.iter().map(String::as_str).collect();
    match arguments.as_slice() {
        ["arm", rest @ ..] => {
            let hours = match rest {
                [] => DEFAULT_HOURS,
                ["--hours", value] => value
                    .parse::<f64>()
                    .ok()
                    .filter(|h| *h > 0.0 && *h <= MAX_HOURS)
                    .unwrap_or_else(|| fail(&format!("--hours must be above 0 and at most {MAX_HOURS}"))),
                _ => fail("usage: claude-goal arm [--hours N] < condition"),
            };
            let mut condition = String::new();
            let _ = std::io::stdin().read_to_string(&mut condition);
            let condition = condition.trim().to_string();
            if condition.is_empty() || condition.chars().count() > MAX_CONDITION {
                fail(&format!("the condition (on stdin) must be 1-{MAX_CONDITION} characters"));
            }
            let goal = Goal { condition, armed: now(), deadline: now() + hours * 3600.0, continuations: 0 };
            write_atomically(&path, &goal).unwrap_or_else(|e| fail(&format!("cannot save the goal: {e}")));
            log(&directory, &session, "armed", json!({"hours": hours}));
            println!(
                "Goal armed for session {session} until {} (at most {MAX_CONTINUATIONS} forced continuations):\n{}",
                utc(goal.deadline),
                goal.condition
            );
        }
        [] | ["status"] => match path.is_file().then(|| read_goal(&path)).flatten() {
            None => println!("No goal armed for session {session}."),
            Some(goal) => println!(
                "Goal for session {session}, until {}, {}/{MAX_CONTINUATIONS} forced continuations used:\n{}",
                utc(goal.deadline),
                goal.continuations,
                goal.condition
            ),
        },
        [command @ ("met" | "clear"), note] if !note.trim().is_empty() => {
            if !path.is_file() {
                fail(&format!("no goal armed for session {session}"));
            }
            fs::remove_file(&path).unwrap_or_else(|e| fail(&format!("cannot disarm: {e}")));
            log(&directory, &session, command, json!({"note": note.trim()}));
            println!("Goal {}: {}", if *command == "met" { "met" } else { "cleared" }, note.trim());
        }
        _ => fail("usage: claude-goal [status | arm [--hours N] < condition | met EVIDENCE | clear REASON]"),
    }
}

fn main() {
    let arguments: Vec<String> = std::env::args().skip(1).collect();
    if arguments == ["hook"] {
        // Fail open: a panic or any error lets the session stop.
        std::panic::set_hook(Box::new(|_| {}));
        if let Ok(Some(line)) = std::panic::catch_unwind(hook) {
            println!("{line}");
        }
        exit(0);
    }
    cli(&arguments);
}
