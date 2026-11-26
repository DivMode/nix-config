//! Blocking rules of the session goal, run against the built binary. A goal
//! that blocks a session it was not armed for, blocks forever, busy-waits a
//! session that has a wake scheduled, or blocks without a saved count would
//! bring back the 2026-10-31 Stop loop.

use serde_json::{json, Value};
use std::fs;
use std::io::Write;
use std::os::unix::fs::PermissionsExt;
use std::path::{Path, PathBuf};
use std::process::{Command, Output, Stdio};
use std::sync::atomic::{AtomicUsize, Ordering};

const BIN: &str = env!("CARGO_BIN_EXE_claude-goal");
const SESSION: &str = "0d9f6c2e-goal-test";

fn state() -> PathBuf {
    static NEXT: AtomicUsize = AtomicUsize::new(0);
    let dir = std::env::temp_dir().join(format!(
        "claude-goal-test-{}-{}",
        std::process::id(),
        NEXT.fetch_add(1, Ordering::SeqCst)
    ));
    fs::create_dir_all(&dir).unwrap();
    dir
}

fn run(state: &Path, args: &[&str], stdin: &str, session: &str) -> Output {
    let mut child = Command::new(BIN)
        .args(args)
        .env_clear()
        .env("XDG_STATE_HOME", state)
        .env("CLAUDE_CODE_SESSION_ID", session)
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .unwrap();
    child.stdin.take().unwrap().write_all(stdin.as_bytes()).unwrap();
    child.wait_with_output().unwrap()
}

fn stop_with(state: &Path, session: &str, extra: Value) -> String {
    let mut event = json!({"hook_event_name": "Stop", "session_id": session, "cwd": "/",
                           "stop_hook_active": false, "background_tasks": [], "session_crons": []});
    event.as_object_mut().unwrap().extend(extra.as_object().unwrap().clone());
    let output = run(state, &["hook"], &event.to_string(), "");
    assert!(output.status.success());
    String::from_utf8(output.stdout).unwrap()
}

fn stop(state: &Path) -> String {
    stop_with(state, SESSION, json!({}))
}

fn goal_file(state: &Path) -> PathBuf {
    state.join("claude-goals").join(format!("{SESSION}.json"))
}

fn count(state: &Path) -> i64 {
    serde_json::from_str::<Value>(&fs::read_to_string(goal_file(state)).unwrap()).unwrap()["continuations"]
        .as_i64()
        .unwrap()
}

fn edit(state: &Path, field: &str, value: Value) {
    let mut goal: Value = serde_json::from_str(&fs::read_to_string(goal_file(state)).unwrap()).unwrap();
    goal[field] = value;
    fs::write(goal_file(state), goal.to_string()).unwrap();
}

fn armed(condition: &str) -> PathBuf {
    let state = state();
    assert!(run(&state, &["arm"], condition, SESSION).status.success());
    state
}

#[test]
fn no_goal_lets_the_session_stop() {
    assert_eq!(stop(&state()), "");
}

#[test]
fn armed_goal_blocks_only_its_own_session_and_counts() {
    let state = armed("PR 12 is merged with green checks");
    let decision: Value = serde_json::from_str(&stop(&state)).unwrap();
    assert_eq!(decision.as_object().unwrap().len(), 2);
    assert_eq!(decision["decision"], "block");
    assert!(decision["reason"].as_str().unwrap().contains("PR 12 is merged"));
    assert_eq!(count(&state), 1);
    assert_eq!(stop_with(&state, "another-session", json!({})), "");
    assert_eq!(stop_with(&state, "../claude-goals/x", json!({})), "");
}

#[test]
fn a_pending_wake_lets_the_session_idle_uncounted() {
    let state = armed("x");
    for key in ["session_crons", "background_tasks"] {
        assert_eq!(stop_with(&state, SESSION, json!({key: [{"id": "wake"}]})), "", "{key}");
    }
    assert_eq!(count(&state), 0);
}

#[test]
fn deadline_and_cap_disarm() {
    let state = armed("x");
    edit(&state, "deadline", json!(1.0));
    assert_eq!(stop(&state), "");
    assert!(!goal_file(&state).exists());

    let state = armed("x");
    edit(&state, "continuations", json!(200));
    assert_eq!(stop(&state), "");
    assert!(!goal_file(&state).exists());
}

#[test]
fn an_unreadable_goal_lets_the_session_stop() {
    let state = armed("x");
    edit(&state, "condition", json!(""));
    assert_eq!(stop(&state), "");
}

#[test]
fn a_count_that_cannot_be_saved_is_never_sent() {
    if unsafe_root() {
        return;
    }
    let state = armed("x");
    let directory = goal_file(&state).parent().unwrap().to_path_buf();
    fs::set_permissions(&directory, fs::Permissions::from_mode(0o500)).unwrap();
    let output = stop(&state);
    fs::set_permissions(&directory, fs::Permissions::from_mode(0o700)).unwrap();
    assert_eq!(output, "");
}

fn unsafe_root() -> bool {
    // Permission bits do not stop root; the case cannot be observed there.
    Command::new("id").arg("-u").output().map(|o| o.stdout == b"0\n").unwrap_or(false)
}

#[test]
fn a_long_non_ascii_condition_fits_one_pipe_write() {
    let state = armed(&"ü".repeat(3000));
    let output = stop(&state);
    assert!(output.len() <= 512, "{}", output.len());
    assert_eq!(serde_json::from_str::<Value>(&output).unwrap()["decision"], "block");
}

#[test]
fn cli_status_met_clear_and_log() {
    let state = armed("PR 12 is merged");
    stop(&state);
    let status = String::from_utf8(run(&state, &["status"], "", SESSION).stdout).unwrap();
    assert!(status.contains("PR 12 is merged") && status.contains("1/200"), "{status}");
    assert!(run(&state, &["met", "gh pr view 12: MERGED"], "", SESSION).status.success());
    assert!(!goal_file(&state).exists());
    assert_eq!(stop(&state), "");
    let log = fs::read_to_string(state.join("claude-goals/log.jsonl")).unwrap();
    let events: Vec<String> = log
        .lines()
        .map(|l| serde_json::from_str::<Value>(l).unwrap()["event"].as_str().unwrap().to_string())
        .collect();
    assert_eq!(events, ["armed", "continued", "met"]);
    assert!(!run(&state, &["clear", "nothing"], "", SESSION).status.success());
    assert!(!run(&state, &["arm"], "  ", SESSION).status.success());
    assert!(!run(&state, &["arm", "--hours", "1000"], "x", SESSION).status.success());
    assert!(!run(&state, &["status"], "", "").status.success());
}
