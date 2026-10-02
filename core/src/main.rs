use std::io::{self, BufReader, BufWriter};

use im_thinking_core::ipc::{
    ClientCommand, LineRead, PROTOCOL_VERSION, ServerWriter, read_bounded_line,
};

fn main() {
    if let Err(error) = run() {
        eprintln!("im-thinking-core: {error}");
        std::process::exit(1);
    }
}

fn run() -> io::Result<()> {
    let stdin = io::stdin();
    let stdout = io::stdout();
    let mut input = BufReader::new(stdin.lock());
    let mut output = ServerWriter::new(BufWriter::new(stdout.lock()));

    output.hello()?;

    loop {
        let line = match read_bounded_line(&mut input)? {
            LineRead::Eof => break,
            LineRead::Oversized => {
                output.error("warning", "IPC1003", "ipc", true)?;
                continue;
            }
            LineRead::Data(line) if line.is_empty() => continue,
            LineRead::Data(line) => line,
        };

        let command: ClientCommand = match serde_json::from_slice(&line) {
            Ok(command) => command,
            Err(_) => {
                output.error("warning", "IPC1002", "ipc", true)?;
                continue;
            }
        };

        if command.version() != PROTOCOL_VERSION {
            output.error("fatal", "IPC1001", "ipc", false)?;
            return Err(io::Error::new(
                io::ErrorKind::InvalidData,
                "unsupported IPC protocol version",
            ));
        }

        match command {
            ClientCommand::Configure {
                agents,
                extra_roots,
                ..
            } => {
                let _ = (agents.claude, agents.codex, extra_roots.len());
                output.ready()?;
            }
            ClientCommand::SetAgentEnabled { agent, enabled, .. } => {
                let _ = (agent, enabled);
            }
            ClientCommand::Rescan { .. } => {}
            ClientCommand::Ping { id, .. } => output.pong(id)?,
            ClientCommand::Shutdown { .. } => break,
        }
    }

    Ok(())
}
