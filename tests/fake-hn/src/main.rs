//! Fake `hn` for integration tests and the WS-QA canary.
//! Appends one JSON line per call to $HN_FAKE_LOG (default ~/.humanneeded-fake/calls.jsonl):
//!   {"ts":<ms>,"args":[...],"stdin":"<first 16 KB>","cwd":"...","env":{...}}
//! Like the real `hn` (app-events §1): prints nothing, always exits 0.
use std::io::{Read, Write};
use std::time::{SystemTime, UNIX_EPOCH};

const ENV_KEYS: &[&str] = &[
    "CLAUDE_CODE_REMOTE", "CLAUDE_PLUGIN_ROOT", "CLAUDE_PROJECT_DIR",
    "CURSOR_VERSION", "CURSOR_PROJECT_DIR", "PLUGIN_ROOT", "CODEX_HOME",
];

fn esc(s: &str) -> String {
    let mut o = String::with_capacity(s.len() + 2);
    o.push('"');
    for c in s.chars() {
        match c {
            '"' => o.push_str("\\\""),
            '\\' => o.push_str("\\\\"),
            '\n' => o.push_str("\\n"),
            '\r' => o.push_str("\\r"),
            '\t' => o.push_str("\\t"),
            c if (c as u32) < 0x20 => o.push_str(&format!("\\u{:04x}", c as u32)),
            c => o.push(c),
        }
    }
    o.push('"');
    o
}

fn main() {
    let _ = run();
    std::process::exit(0);
}

fn run() -> std::io::Result<()> {
    let args: Vec<String> = std::env::args().skip(1).collect();
    let mut stdin = String::new();
    if args.iter().any(|a| a == "--stdin-json") {
        let mut buf = Vec::new();
        std::io::stdin().take(16 * 1024).read_to_end(&mut buf)?;
        // drain the rest so a big hook payload never blocks the writer
        let _ = std::io::copy(&mut std::io::stdin(), &mut std::io::sink());
        stdin = String::from_utf8_lossy(&buf).into_owned();
    }
    let ts = SystemTime::now().duration_since(UNIX_EPOCH).map(|d| d.as_millis()).unwrap_or(0);
    let cwd = std::env::current_dir().map(|p| p.display().to_string()).unwrap_or_default();
    let env: Vec<String> = ENV_KEYS
        .iter()
        .filter_map(|k| std::env::var(k).ok().map(|v| format!("{}:{}", esc(k), esc(&v))))
        .collect();
    let line = format!(
        "{{\"ts\":{},\"args\":[{}],\"stdin\":{},\"cwd\":{},\"env\":{{{}}}}}\n",
        ts,
        args.iter().map(|a| esc(a)).collect::<Vec<_>>().join(","),
        esc(&stdin),
        esc(&cwd),
        env.join(",")
    );
    let path = match std::env::var("HN_FAKE_LOG") {
        Ok(p) if !p.is_empty() => std::path::PathBuf::from(p),
        _ => {
            let home = std::env::var("HOME").or_else(|_| std::env::var("USERPROFILE")).unwrap_or_default();
            std::path::Path::new(&home).join(".humanneeded-fake").join("calls.jsonl")
        }
    };
    if let Some(dir) = path.parent() {
        std::fs::create_dir_all(dir)?;
    }
    let mut f = std::fs::OpenOptions::new().create(true).append(true).open(path)?;
    f.write_all(line.as_bytes())
}
