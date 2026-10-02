use std::fs;
use std::io::{BufRead, BufReader, Write};
use std::process::{Command, Stdio};
use std::time::{SystemTime, UNIX_EPOCH};

#[test]
fn core_handshake_ping_and_shutdown() {
    let home = std::env::temp_dir().join(format!(
        "im-thinking-ipc-{}-{}",
        std::process::id(),
        SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap()
            .as_nanos()
    ));
    fs::create_dir_all(&home).unwrap();

    let mut child = Command::new(env!("CARGO_BIN_EXE_im-thinking-core"))
        .env("HOME", &home)
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::null())
        .spawn()
        .unwrap();

    let mut stdin = child.stdin.take().unwrap();
    let mut stdout = BufReader::new(child.stdout.take().unwrap());

    let hello = read_json(&mut stdout);
    assert_eq!(hello["type"], "hello");

    let configure = serde_json::json!({
        "v": 1,
        "type": "configure",
        "agents": {
            "claude": true,
            "codex": true
        },
        "roots": {
            "claude": [{
                "path": home.join("claude").to_string_lossy()
            }],
            "codex": []
        }
    })
    .to_string();
    write_command(&mut stdin, &configure);

    let ready = read_json(&mut stdout);
    assert_eq!(ready["type"], "ready");

    write_command(&mut stdin, r#"{"v":1,"type":"ping","id":42}"#);

    let mut saw_pong = false;
    for _ in 0..8 {
        let message = read_json(&mut stdout);
        if message["type"] == "pong" {
            assert_eq!(message["id"], 42);
            saw_pong = true;
            break;
        }
    }
    assert!(saw_pong);

    write_command(&mut stdin, r#"{"v":1,"type":"shutdown"}"#);
    drop(stdin);

    let status = child.wait().unwrap();
    assert!(status.success());
    let _ = fs::remove_dir_all(home);
}

fn write_command(writer: &mut impl Write, command: &str) {
    writer.write_all(command.as_bytes()).unwrap();
    writer.write_all(b"\n").unwrap();
    writer.flush().unwrap();
}

fn read_json(reader: &mut impl BufRead) -> serde_json::Value {
    let mut line = String::new();
    reader.read_line(&mut line).unwrap();
    assert!(!line.is_empty());
    serde_json::from_str(&line).unwrap()
}
