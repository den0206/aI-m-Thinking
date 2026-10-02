use std::collections::HashMap;
use std::fs::{self, File};
use std::io::{self, Seek};
use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex, mpsc};
use std::thread::{self, JoinHandle};
use std::time::{Duration, Instant, SystemTime};

use crate::activity::ActivityEngine;
use crate::events::{AgentState, NormalizedEvent, ToolClass};
use crate::ipc::{AgentFlags, AgentKind, AgentRoots, RootGrant, ServerWriter};
use crate::jsonl::{FILE_SCAN_BUDGET, FileCursor, record_reader, scan_records};
use crate::observer::{ChangeEvent, ChangeKind, FileObserver};
use crate::parsers::{ClaudeParser, CodexParser};
use crate::sandbox::{ScopedRoot, resolve_transfer_bookmark};

const MAX_ACTIVE_SESSIONS: usize = 64;
const MAX_BASELINES_PER_AGENT: usize = 128;
const MAX_CONFIGURED_ROOTS_PER_AGENT: usize = 4;
const MAX_DISCOVERY_ENTRIES: usize = 4096;
const SAMPLE_INTERVAL: Duration = Duration::from_millis(100);

pub enum MonitorCommand {
    SetEnabled { agent: AgentKind, enabled: bool },
    Rescan,
    Shutdown,
}

pub struct MonitorHandle {
    tx: mpsc::Sender<MonitorCommand>,
    join: Option<JoinHandle<()>>,
}

impl MonitorHandle {
    pub fn set_enabled(&self, agent: AgentKind, enabled: bool) {
        let _ = self.tx.send(MonitorCommand::SetEnabled { agent, enabled });
    }

    pub fn rescan(&self) {
        let _ = self.tx.send(MonitorCommand::Rescan);
    }

    pub fn shutdown(mut self) {
        let _ = self.tx.send(MonitorCommand::Shutdown);
        if let Some(join) = self.join.take() {
            let _ = join.join();
        }
    }
}

pub fn spawn_monitor<W>(
    writer: Arc<Mutex<ServerWriter<W>>>,
    flags: AgentFlags,
    roots: AgentRoots,
) -> MonitorHandle
where
    W: io::Write + Send + 'static,
{
    let (command_tx, command_rx) = mpsc::channel();
    let join = thread::spawn(move || {
        let mut runtime = MonitorRuntime::new(writer, flags, roots);
        runtime.run(command_rx);
    });

    MonitorHandle {
        tx: command_tx,
        join: Some(join),
    }
}

struct AgentRoot {
    kind: AgentKind,
    path: PathBuf,
    enabled: bool,
    watcher: Option<FileObserver>,
    _scope: Option<ScopedRoot>,
}

struct Baseline {
    agent: AgentKind,
    cursor: FileCursor,
}

enum Parser {
    Claude(ClaudeParser),
    Codex(CodexParser),
}

impl Parser {
    fn new(agent: AgentKind) -> Self {
        match agent {
            AgentKind::Claude => Self::Claude(ClaudeParser::default()),
            AgentKind::Codex => Self::Codex(CodexParser::default()),
        }
    }

    fn parse(&mut self, reader: impl io::Read) -> serde_json::Result<Vec<NormalizedEvent>> {
        match self {
            Self::Claude(parser) => parser.parse(reader),
            Self::Codex(parser) => parser.parse(reader),
        }
    }
}

struct Session {
    handle: u32,
    agent: AgentKind,
    file: File,
    cursor: FileCursor,
    parser: Parser,
    activity: ActivityEngine,
    dirty: bool,
    last_event_at: Duration,
    last_phase: AgentState,
}

impl Session {
    fn mutation_tool(&self) -> Option<ToolClass> {
        self.activity
            .state()
            .has_mutation_tool()
            .then_some(ToolClass::Mutation)
    }
}

struct MonitorRuntime<W: io::Write + Send + 'static> {
    writer: Arc<Mutex<ServerWriter<W>>>,
    roots: Vec<AgentRoot>,
    baselines: HashMap<PathBuf, Baseline>,
    sessions: HashMap<PathBuf, Session>,
    event_tx: mpsc::Sender<ChangeEvent>,
    event_rx: mpsc::Receiver<ChangeEvent>,
    started: Instant,
    next_handle: u32,
}

impl<W: io::Write + Send + 'static> MonitorRuntime<W> {
    fn new(writer: Arc<Mutex<ServerWriter<W>>>, flags: AgentFlags, roots: AgentRoots) -> Self {
        let (event_tx, event_rx) = mpsc::channel();
        let mut configured_roots = Vec::new();

        configured_roots.extend(resolve_root_grants(
            AgentKind::Claude,
            roots.claude,
            flags.claude,
        ));
        configured_roots.extend(resolve_root_grants(
            AgentKind::Codex,
            roots.codex,
            flags.codex,
        ));

        Self {
            writer,
            roots: configured_roots,
            baselines: HashMap::new(),
            sessions: HashMap::new(),
            event_tx,
            event_rx,
            started: Instant::now(),
            next_handle: 1,
        }
    }

    fn run(&mut self, commands: mpsc::Receiver<MonitorCommand>) {
        self.rescan_roots();

        loop {
            while let Ok(command) = commands.try_recv() {
                match command {
                    MonitorCommand::SetEnabled { agent, enabled } => {
                        let changed = if let Some(root) =
                            self.roots.iter_mut().find(|root| root.kind == agent)
                        {
                            root.enabled = enabled;
                            true
                        } else {
                            false
                        };

                        if changed {
                            if enabled {
                                self.rescan_roots();
                            } else {
                                self.status(agent, "disabled");
                            }
                        }
                    }
                    MonitorCommand::Rescan => self.rescan_roots(),
                    MonitorCommand::Shutdown => {
                        self.close_all_sessions();
                        return;
                    }
                }
            }

            match self.event_rx.recv_timeout(SAMPLE_INTERVAL) {
                Ok(event) => self.handle_change(event),
                Err(mpsc::RecvTimeoutError::Timeout) => {}
                Err(mpsc::RecvTimeoutError::Disconnected) => return,
            }

            while let Ok(event) = self.event_rx.try_recv() {
                self.handle_change(event);
            }

            self.process_dirty_sessions();
            self.emit_activity();
        }
    }

    fn rescan_roots(&mut self) {
        for index in 0..self.roots.len() {
            let enabled = self.roots[index].enabled;
            let kind = self.roots[index].kind;
            let path = self.roots[index].path.clone();

            if !enabled {
                self.status(kind, "disabled");
                continue;
            }

            if !path.is_dir() {
                self.roots[index].watcher = None;
                self.status(kind, "directory_missing");
                continue;
            }

            if self.roots[index].watcher.is_none() {
                match FileObserver::watch(&path, self.event_tx.clone()) {
                    Ok(watcher) => self.roots[index].watcher = Some(watcher),
                    Err(_) => {
                        self.status(kind, "error");
                        continue;
                    }
                }
            }

            self.baseline_root(kind, &path);
            self.status(kind, "monitoring");
        }
    }

    fn baseline_root(&mut self, agent: AgentKind, root: &Path) {
        let existing = self
            .baselines
            .values()
            .filter(|baseline| baseline.agent == agent)
            .count();
        let remaining = MAX_BASELINES_PER_AGENT.saturating_sub(existing);
        if remaining == 0 {
            return;
        }

        let mut candidates = discover_jsonl(root);
        candidates.sort_by_key(|(_, modified)| std::cmp::Reverse(*modified));

        for (path, _) in candidates.into_iter().take(remaining) {
            if self.sessions.contains_key(&path) || self.baselines.contains_key(&path) {
                continue;
            }

            if let Ok((_file, cursor)) = FileCursor::baseline(&path) {
                self.baselines.insert(path, Baseline { agent, cursor });
            }
        }
    }

    fn handle_change(&mut self, event: ChangeEvent) {
        for path in event.paths {
            if path.extension().and_then(|value| value.to_str()) != Some("jsonl") {
                continue;
            }

            let Some(agent) = self.agent_for_path(&path) else {
                continue;
            };
            if !self.agent_enabled(agent) {
                continue;
            }

            match event.kind {
                ChangeKind::Create => self.open_new_session(path, agent),
                ChangeKind::Modify => self.mark_modified(path, agent),
                ChangeKind::RemoveOrRename => self.close_path(&path),
                ChangeKind::Other => {}
            }
        }
    }

    fn open_new_session(&mut self, path: PathBuf, agent: AgentKind) {
        if self.sessions.contains_key(&path) {
            if let Some(session) = self.sessions.get_mut(&path) {
                session.dirty = true;
            }
            return;
        }

        let Ok(file) = File::open(&path) else {
            return;
        };
        let Ok(cursor) = FileCursor::from_start(&file) else {
            return;
        };
        self.insert_session(path, agent, file, cursor, true);
    }

    fn mark_modified(&mut self, path: PathBuf, agent: AgentKind) {
        if let Some(session) = self.sessions.get_mut(&path) {
            if let Ok(reopened) = File::open(&path) {
                match session.cursor.refresh(&reopened) {
                    Ok(crate::jsonl::RefreshOutcome::Unchanged) => {
                        session.file = reopened;
                        session.dirty = true;
                    }
                    Ok(crate::jsonl::RefreshOutcome::Replaced)
                    | Ok(crate::jsonl::RefreshOutcome::Truncated) => {
                        session.file = reopened;
                        session.dirty = false;
                    }
                    Err(_) => {}
                }
            }
            return;
        }

        if let Some(baseline) = self.baselines.remove(&path) {
            let Ok(file) = File::open(&path) else {
                return;
            };
            let mut cursor = baseline.cursor;
            if cursor.refresh(&file).is_err() {
                return;
            }
            self.insert_session(path, baseline.agent, file, cursor, true);
            return;
        }

        // Unknown pre-existing file: baseline at current EOF rather than replaying
        // historical content. A future append will be observed normally.
        if let Ok((_file, cursor)) = FileCursor::baseline(&path) {
            let agent_count = self
                .baselines
                .values()
                .filter(|baseline| baseline.agent == agent)
                .count();
            if agent_count < MAX_BASELINES_PER_AGENT {
                self.baselines.insert(path, Baseline { agent, cursor });
            }
        }
    }

    fn insert_session(
        &mut self,
        path: PathBuf,
        agent: AgentKind,
        file: File,
        cursor: FileCursor,
        dirty: bool,
    ) {
        if self.sessions.len() >= MAX_ACTIVE_SESSIONS && !self.evict_idle_session() {
            self.error("WATCH2006", "observer");
            return;
        }

        let now = self.now();
        let handle = self.next_handle;
        self.next_handle = self.next_handle.wrapping_add(1).max(1);

        let session = Session {
            handle,
            agent,
            file,
            cursor,
            parser: Parser::new(agent),
            activity: ActivityEngine::new(now),
            dirty,
            last_event_at: now,
            last_phase: AgentState::Idle,
        };

        self.sessions.insert(path, session);
        self.with_writer(|writer| writer.session_opened(handle, agent));
    }

    fn evict_idle_session(&mut self) -> bool {
        let candidate = self
            .sessions
            .iter()
            .filter(|(_, session)| session.activity.state().phase() == AgentState::Idle)
            .min_by_key(|(_, session)| session.last_event_at)
            .map(|(path, _)| path.clone());

        if let Some(path) = candidate {
            self.close_path(&path);
            true
        } else {
            false
        }
    }

    fn close_path(&mut self, path: &Path) {
        self.baselines.remove(path);
        if let Some(session) = self.sessions.remove(path) {
            self.with_writer(|writer| writer.session_closed(session.handle, session.agent));
        }
    }

    fn close_all_sessions(&mut self) {
        let sessions: Vec<_> = self
            .sessions
            .drain()
            .map(|(_, session)| (session.handle, session.agent))
            .collect();

        for (handle, agent) in sessions {
            self.with_writer(|writer| writer.session_closed(handle, agent));
        }
    }

    fn process_dirty_sessions(&mut self) {
        let paths: Vec<_> = self
            .sessions
            .iter()
            .filter(|(_, session)| session.dirty)
            .map(|(path, _)| path.clone())
            .collect();

        for path in paths {
            self.process_session(&path);
        }
    }

    fn process_session(&mut self, path: &Path) {
        let now = self.now();
        let Some(session) = self.sessions.get_mut(path) else {
            return;
        };

        let result = match scan_records(&mut session.file, &mut session.cursor, FILE_SCAN_BUDGET) {
            Ok(result) => result,
            Err(_) => {
                session.dirty = false;
                return;
            }
        };

        let mut saw_event = false;
        for range in result.records {
            let parsed = match record_reader(&mut session.file, range) {
                Ok(reader) => session.parser.parse(reader),
                Err(_) => continue,
            };

            session.cursor.commit_through(range.next_offset);

            let Ok(events) = parsed else {
                continue;
            };

            for event in events {
                session.activity.apply(&event, now);
                session.last_event_at = now;
                saw_event = true;
            }
        }

        let eof = session
            .file
            .seek(io::SeekFrom::End(0))
            .unwrap_or(session.cursor.scan_offset());
        session.dirty = session.cursor.scan_offset() < eof;

        if saw_event {
            let sample = session.activity.sample(now);
            session.last_phase = sample.phase;
        }
    }

    fn emit_activity(&mut self) {
        let now = self.now();
        let at_ms = now.as_millis().min(u64::MAX as u128) as u64;

        let samples: Vec<_> = self
            .sessions
            .values_mut()
            .filter_map(|session| {
                let sample = session.activity.sample(now);
                let should_emit = session.activity.state().turn_open()
                    || sample.intensity > 0.005
                    || sample.phase != session.last_phase;

                session.last_phase = sample.phase;
                should_emit.then_some((
                    session.handle,
                    session.agent,
                    sample,
                    session.mutation_tool(),
                ))
            })
            .collect();

        for (handle, agent, sample, tool_class) in samples {
            self.with_writer(|writer| writer.activity(handle, agent, sample, tool_class, at_ms));
        }
    }

    fn agent_for_path(&self, path: &Path) -> Option<AgentKind> {
        self.roots
            .iter()
            .find(|root| path.starts_with(&root.path))
            .map(|root| root.kind)
    }

    fn agent_enabled(&self, agent: AgentKind) -> bool {
        self.roots
            .iter()
            .find(|root| root.kind == agent)
            .is_some_and(|root| root.enabled)
    }

    fn now(&self) -> Duration {
        self.started.elapsed()
    }

    fn status(&self, agent: AgentKind, status: &'static str) {
        self.with_writer(|writer| writer.observer_status(agent, status));
    }

    fn error(&self, code: &'static str, component: &'static str) {
        self.with_writer(|writer| writer.error("warning", code, component, true));
    }

    fn with_writer(&self, action: impl FnOnce(&mut ServerWriter<W>) -> io::Result<()>) {
        if let Ok(mut writer) = self.writer.lock() {
            let _ = action(&mut writer);
        }
    }
}

fn discover_jsonl(root: &Path) -> Vec<(PathBuf, SystemTime)> {
    let mut found = Vec::new();
    let mut stack = vec![root.to_path_buf()];
    let mut visited = 0usize;

    while let Some(directory) = stack.pop() {
        if visited >= MAX_DISCOVERY_ENTRIES {
            break;
        }
        visited += 1;

        let Ok(entries) = fs::read_dir(directory) else {
            continue;
        };

        for entry in entries.flatten() {
            if found.len() >= MAX_DISCOVERY_ENTRIES {
                break;
            }

            let path = entry.path();
            let Ok(metadata) = entry.metadata() else {
                continue;
            };

            if metadata.is_dir() {
                stack.push(path);
            } else if metadata.is_file()
                && path.extension().and_then(|value| value.to_str()) == Some("jsonl")
            {
                found.push((path, metadata.modified().unwrap_or(SystemTime::UNIX_EPOCH)));
            }
        }
    }

    found
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn discovery_only_returns_jsonl_files() {
        let root = std::env::temp_dir().join(format!("im-thinking-runtime-{}", std::process::id()));
        let _ = fs::remove_dir_all(&root);
        fs::create_dir_all(root.join("nested")).unwrap();
        fs::write(root.join("a.jsonl"), b"{}\n").unwrap();
        fs::write(root.join("ignore.txt"), b"x").unwrap();
        fs::write(root.join("nested/b.jsonl"), b"{}\n").unwrap();

        let files = discover_jsonl(&root);
        assert_eq!(files.len(), 2);
        assert!(
            files
                .iter()
                .all(|(path, _)| path.extension().unwrap() == "jsonl")
        );

        let _ = fs::remove_dir_all(root);
    }
}

fn resolve_root_grants(agent: AgentKind, grants: Vec<RootGrant>, enabled: bool) -> Vec<AgentRoot> {
    grants
        .into_iter()
        .take(MAX_CONFIGURED_ROOTS_PER_AGENT)
        .filter_map(|grant| {
            if let Some(bookmark) = grant.bookmark {
                let scope = resolve_transfer_bookmark(&bookmark).ok()?;
                return Some(AgentRoot {
                    kind: agent,
                    path: scope.path().to_path_buf(),
                    enabled,
                    watcher: None,
                    _scope: Some(scope),
                });
            }

            let path = grant.path?;
            if path.is_empty() {
                return None;
            }

            Some(AgentRoot {
                kind: agent,
                path: PathBuf::from(path),
                enabled,
                watcher: None,
                _scope: None,
            })
        })
        .collect()
}
