use std::io::{self, BufReader, BufWriter};
use std::sync::{Arc, Mutex};

use im_thinking_core::ipc::{
    ClientCommand, LineRead, PROTOCOL_VERSION, ServerWriter, read_bounded_line,
};
use im_thinking_core::runtime::{MonitorHandle, spawn_monitor};

fn main() {
    if let Err(error) = run() {
        eprintln!("im-thinking-core: {error}");
        std::process::exit(1);
    }
}

fn run() -> io::Result<()> {
    let stdin = io::stdin();
    let mut input = BufReader::new(stdin.lock());
    let writer = Arc::new(Mutex::new(ServerWriter::new(BufWriter::new(io::stdout()))));
    let mut monitor: Option<MonitorHandle> = None;

    with_writer(&writer, |writer| writer.hello())?;

    loop {
        let line = match read_bounded_line(&mut input)? {
            LineRead::Eof => break,
            LineRead::Oversized => {
                with_writer(&writer, |writer| {
                    writer.error("warning", "IPC1003", "ipc", true)
                })?;
                continue;
            }
            LineRead::Data(line) if line.is_empty() => continue,
            LineRead::Data(line) => line,
        };

        let command: ClientCommand = match serde_json::from_slice(&line) {
            Ok(command) => command,
            Err(_) => {
                with_writer(&writer, |writer| {
                    writer.error("warning", "IPC1002", "ipc", true)
                })?;
                continue;
            }
        };

        if command.version() != PROTOCOL_VERSION {
            with_writer(&writer, |writer| {
                writer.error("fatal", "IPC1001", "ipc", false)
            })?;
            return Err(io::Error::new(
                io::ErrorKind::InvalidData,
                "unsupported IPC protocol version",
            ));
        }

        match command {
            ClientCommand::Configure { agents, roots, .. } => {
                if let Some(existing) = monitor.take() {
                    existing.shutdown();
                }

                // Complete the handshake before observer/session events can be emitted.
                with_writer(&writer, |writer| writer.ready())?;
                monitor = Some(spawn_monitor(Arc::clone(&writer), agents, roots));
            }
            ClientCommand::SetAgentEnabled { agent, enabled, .. } => {
                if let Some(monitor) = &monitor {
                    monitor.set_enabled(agent, enabled);
                }
            }
            ClientCommand::Rescan { .. } => {
                if let Some(monitor) = &monitor {
                    monitor.rescan();
                }
            }
            ClientCommand::Ping { id, .. } => {
                with_writer(&writer, |writer| writer.pong(id))?;
            }
            ClientCommand::Shutdown { .. } => break,
        }
    }

    if let Some(monitor) = monitor {
        monitor.shutdown();
    }

    Ok(())
}

fn with_writer<W: io::Write>(
    writer: &Arc<Mutex<ServerWriter<W>>>,
    action: impl FnOnce(&mut ServerWriter<W>) -> io::Result<()>,
) -> io::Result<()> {
    let mut writer = writer
        .lock()
        .map_err(|_| io::Error::other("IPC writer lock poisoned"))?;
    action(&mut writer)
}
