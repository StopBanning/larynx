//! Tests only (never shipped: ci/stage.ps1 copies larynx.exe and larynx-cli.exe alone). Stands in for Claude Code's
//! `claude.exe` in the meeting end-to-end test: it writes what it was given (its arguments, whether an API key reached
//! it, the transcript on stdin) to the file `FAKE_CLAUDE_OUT` names, and answers the way `claude -p --output-format
//! json --json-schema ...` does, with fixed notes for the scripted renovation meeting.

use std::io::Read;

fn main() {
    let args: Vec<String> = std::env::args().skip(1).collect();
    let mut stdin = String::new();
    let _ = std::io::stdin().read_to_string(&mut stdin);
    if let Ok(path) = std::env::var("FAKE_CLAUDE_OUT") {
        let record = serde_json::json!({
            "args": args,
            "api_key_reached_claude_code": std::env::var_os("ANTHROPIC_API_KEY").is_some(),
            "auth_token_reached_claude_code": std::env::var_os("ANTHROPIC_AUTH_TOKEN").is_some(),
            "stdin": stdin,
            "cwd": std::env::current_dir().map(|d| d.to_string_lossy().into_owned()).unwrap_or_default(),
        });
        let _ = std::fs::write(path, serde_json::to_string_pretty(&record).unwrap());
    }
    let notes = serde_json::json!({
        "title": "Renovation schedule (through Claude Code)",
        "summary": ["You and Priya went over the renovation: the kitchen is on track and the bathroom tile is back-ordered."],
        "decisions": ["Keep the upgraded faucets."],
        "actionItems": [{"task": "Send photos of the two tiles in stock", "owner": "Priya", "due": "tonight"}],
        "openQuestions": ["Whether the electrician can start early."]
    });
    let reply = serde_json::json!({"type": "result", "is_error": false, "result": "", "structured_output": notes});
    println!("{reply}");
}
