use std::collections::HashMap;
use std::fs::{self, File, Metadata};
use std::io::{self, BufReader, Read, Seek};
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::mpsc::{self, Receiver, RecvTimeoutError, SyncSender, TrySendError};
use std::sync::{Arc, Mutex};
use std::thread::{self, JoinHandle};
use std::time::{Duration, Instant, SystemTime};

use crate::activity::ActivityEngine;
use crate::events::{AgentState, NormalizedEvent, ParsedRecord, ToolClass};
use crate::ipc::{AgentFlags, AgentKind, AgentRoots, RootGrant, ServerWriter};
use crate::jsonl::{FILE_SCAN_BUDGET, FileCursor, record_reader, scan_records};
use crate::observer::{ChangeEvent, ChangeKind, FileObserver};
use crate::parsers::{ClaudeParser, CodexParser};
use crate::sandbox::{ScopedRoot, resolve_transfer_bookmark};

const MAX_ACTIVE_SESSIONS: usize = 64;
const MAX_BASELINES_PER_AGENT: usize = 4096;
const MAX_CONFIGURED_ROOTS_PER_AGENT: usize = 4;
const MAX_DISCOVERY_ENTRIES: usize = 4096;
const MAX_ACTIVITY_QUEUE: usize = 256;
const ACTIVITY_INTERVAL: Duration = Duration::from_millis(100);
// Native notifications can be unavailable even after a successful watch.
const RECONCILE_INTERVAL: Duration = Duration::from_secs(3);
/// Intensities below this are reported as exact silence.
const ACTIVITY_EPSILON: f32 = 0.005;
/// How long a session keeps being sampled after its last event. Covers the
/// state-baseline freshness window plus the falling smoothing tail.
const SIGNAL_SETTLE: Duration = Duration::from_secs(6);
/// A turn with no signal for this long is closed. Agents may exit or be
/// interrupted without writing a turn-end record.
const STALE_TURN_TIMEOUT: Duration = Duration::from_secs(10 * 60);
/// Creation timestamps can come from a coarse clock, so only files created
/// clearly before monitoring started are treated as pre-existing.
const CREATION_SLACK: Duration = Duration::from_secs(1);
/// Records written longer ago than this are history (for example a Codex
/// rollout restored from `.jsonl.zst` on resume): they update state but never
/// produce sound. Claude Code stamps blocks when they start, up to about a
/// minute before the message is written, so the margin is generous.
const HISTORY_AGE: Duration = Duration::from_secs(10 * 60);
/// Claude Code's per-process status files (`~/.claude/sessions/<pid>.json`)
/// are a few hundred bytes; anything larger is not one.
const MAX_STATUS_FILE_BYTES: u64 = 16 * 1024;
/// serde_json reads one byte per `read()` call, so records are buffered.
const PARSE_BUFFER_BYTES: usize = 8 * 1024;
/// Records a session may write without any of them being understood before
/// the transcript format is reported as unrecognized. Live records count
/// unless their kind is known to be quiet; malformed records count whatever
/// their age, since their timestamp is unreadable. Every active turn writes
/// recognized records well before this, so reaching it means the agent
/// changed its format (or the parser regressed), not that it was quiet.
const UNRECOGNIZED_FORMAT_RECORDS: u32 = 100;

pub enum MonitorCommand {
    Rescan,
    SetSessionPaused { session: u32, paused: bool },
    Shutdown,
}

enum Inbound {
    Change(ChangeEvent),
    Command(MonitorCommand),
}

pub struct MonitorHandle {
    tx: SyncSender<Inbound>,
    join: Option<JoinHandle<()>>,
}

impl MonitorHandle {
    pub fn rescan(&self) {
        self.send(MonitorCommand::Rescan);
    }

    pub fn set_session_paused(&self, session: u32, paused: bool) {
        self.send(MonitorCommand::SetSessionPaused { session, paused });
    }

    pub fn shutdown(self) {
        drop(self);
    }

    fn send(&self, command: MonitorCommand) {
        let _ = self.tx.send(Inbound::Command(command));
    }
}

impl Drop for MonitorHandle {
    fn drop(&mut self) {
        self.send(MonitorCommand::Shutdown);
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
    // Commands and file events share one bounded queue so the monitor thread
    // can block until there is work instead of polling.
    let (tx, rx) = mpsc::sync_channel(MAX_ACTIVITY_QUEUE);
    let inbound = tx.clone();
    let join = thread::spawn(move || {
        let mut runtime = MonitorRuntime::new(writer, flags, roots, inbound);
        runtime.run(&rx);
    });

    MonitorHandle {
        tx,
        join: Some(join),
    }
}

struct AgentRoot {
    kind: AgentKind,
    path: PathBuf,
    watcher: Option<FileObserver>,
    status_watcher: Option<FileObserver>,
    _scope: Option<ScopedRoot>,
}

struct Baseline {
    agent: AgentKind,
    cursor: FileCursor,
    touched: u64,
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

    fn parse(&mut self, reader: impl io::Read) -> serde_json::Result<ParsedRecord> {
        let reader = BufReader::with_capacity(PARSE_BUFFER_BYTES, reader);
        match self {
            Self::Claude(parser) => parser.parse_record(reader),
            Self::Codex(parser) => parser.parse_record(reader),
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
    /// Records that were already present when an external idle signal arrived
    /// must not reopen the interrupted turn, even across scan budgets.
    interrupted_through: Option<u64>,
    paused: bool,
    last_event_at: Duration,
    last_phase: AgentState,
    last_emitted_intensity: f32,
    last_emit_at: Option<Duration>,
    /// Live records seen while none has produced an event; `None` once one
    /// has, or once the format warning was sent.
    unrecognized_records: Option<u32>,
    agent_version: Option<String>,
}

impl Session {
    /// Returns true exactly once, when the session reaches
    /// `UNRECOGNIZED_FORMAT_RECORDS` live records without an event.
    fn count_unrecognized(&mut self, recognized: bool) -> bool {
        let Some(count) = self.unrecognized_records.as_mut() else {
            return false;
        };
        if recognized {
            self.unrecognized_records = None;
            return false;
        }
        *count += 1;
        if *count < UNRECOGNIZED_FORMAT_RECORDS {
            return false;
        }
        self.unrecognized_records = None;
        true
    }

    fn mutation_tool(&self) -> Option<ToolClass> {
        self.activity
            .state()
            .has_mutation_tool()
            .then_some(ToolClass::Mutation)
    }

    /// Time until this session next needs the monitor loop, or `None` when
    /// only a new file event can change its output.
    fn next_wakeup(&self, now: Duration) -> Option<Duration> {
        if self.dirty {
            return Some(Duration::ZERO);
        }

        let since_event = now.saturating_sub(self.last_event_at);
        if self.last_emitted_intensity > 0.0 || since_event < SIGNAL_SETTLE {
            return Some(ACTIVITY_INTERVAL);
        }

        (self.activity.state().phase() != AgentState::Idle)
            .then(|| STALE_TURN_TIMEOUT.saturating_sub(since_event))
    }
}

struct MonitorRuntime<W: io::Write + Send + 'static> {
    writer: Arc<Mutex<ServerWriter<W>>>,
    roots: Vec<AgentRoot>,
    baselines: HashMap<PathBuf, Baseline>,
    baseline_counts: [usize; 2],
    baseline_cap: usize,
    baseline_clock: u64,
    sessions: HashMap<PathBuf, Session>,
    inbound: SyncSender<Inbound>,
    overflow: Arc<AtomicBool>,
    started: Instant,
    started_wall: SystemTime,
    next_handle: u32,
    next_reconcile_at: Duration,
    #[cfg(test)]
    clock_skew: Duration,
}

impl<W: io::Write + Send + 'static> MonitorRuntime<W> {
    fn new(
        writer: Arc<Mutex<ServerWriter<W>>>,
        flags: AgentFlags,
        roots: AgentRoots,
        inbound: SyncSender<Inbound>,
    ) -> Self {
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
            baseline_counts: [0; 2],
            baseline_cap: MAX_BASELINES_PER_AGENT,
            baseline_clock: 0,
            sessions: HashMap::new(),
            inbound,
            overflow: Arc::new(AtomicBool::new(false)),
            started: Instant::now(),
            started_wall: SystemTime::now(),
            next_handle: 1,
            next_reconcile_at: RECONCILE_INTERVAL,
            #[cfg(test)]
            clock_skew: Duration::ZERO,
        }
    }

    fn run(&mut self, inbound: &Receiver<Inbound>) {
        self.rescan_roots();

        loop {
            let first = match self.next_wakeup() {
                None => match inbound.recv() {
                    Ok(message) => Some(message),
                    Err(_) => return,
                },
                Some(timeout) => match inbound.recv_timeout(timeout) {
                    Ok(message) => Some(message),
                    Err(RecvTimeoutError::Timeout) => None,
                    Err(RecvTimeoutError::Disconnected) => return,
                },
            };

            let queued = std::iter::from_fn(|| inbound.try_recv().ok());
            for message in first.into_iter().chain(queued).take(MAX_ACTIVITY_QUEUE) {
                match message {
                    Inbound::Change(event) => self.handle_change(event),
                    Inbound::Command(MonitorCommand::Shutdown) => {
                        self.close_all_sessions();
                        return;
                    }
                    Inbound::Command(command) => self.handle_command(command),
                }
            }

            if self.overflow.swap(false, Ordering::Relaxed) {
                // Dropped notifications may hide appends; re-check every
                // tracked session instead of trusting the queue.
                for session in self.sessions.values_mut() {
                    session.dirty = true;
                }
                self.error("ACT4004", "observer");
                self.reconcile_files();
            }

            if self.now() >= self.next_reconcile_at {
                self.reconcile_files();
                self.next_reconcile_at = self.now() + RECONCILE_INTERVAL;
            }

            self.process_dirty_sessions();
            self.expire_stale_turns();
            self.emit_activity();
        }
    }

    fn handle_command(&mut self, command: MonitorCommand) {
        match command {
            MonitorCommand::Rescan => {
                self.reconcile_files();
                self.rescan_roots();
            }
            MonitorCommand::SetSessionPaused {
                session: handle,
                paused,
            } => {
                let now = self.now();
                if let Some(session) = self
                    .sessions
                    .values_mut()
                    .find(|session| session.handle == handle)
                {
                    if session.paused == paused {
                        return;
                    }
                    session.paused = paused;
                    // Ignore all data written before this command, including partial records.
                    session.interrupted_through =
                        session.file.metadata().ok().map(|metadata| metadata.len());
                    session.activity = ActivityEngine::with_pending_timeout(
                        now,
                        match session.agent {
                            AgentKind::Claude => Duration::from_secs(120),
                            AgentKind::Codex => STALE_TURN_TIMEOUT,
                        },
                    );
                    session.last_event_at = now;
                }
            }
            MonitorCommand::Shutdown => {}
        }
    }

    fn next_wakeup(&self) -> Option<Duration> {
        let now = self.now();
        self.sessions
            .values()
            .filter_map(|session| session.next_wakeup(now))
            .chain(std::iter::once(self.next_reconcile_at.saturating_sub(now)))
            .min()
    }

    /// Reconcile metadata so missing native notifications cannot strand a
    /// baseline or an active session. Existing EOF baselines remain intact.
    fn reconcile_files(&mut self) {
        for index in 0..self.roots.len() {
            let agent = self.roots[index].kind;
            let root = self.roots[index].path.clone();
            for (path, metadata) in discover_jsonl(&root) {
                if let Some(session) = self.sessions.get(&path) {
                    if session.cursor.metadata_changed(&metadata) {
                        self.mark_modified(path, agent);
                    }
                } else if let Some(baseline) = self.baselines.get(&path) {
                    if baseline.cursor.metadata_changed(&metadata) {
                        eprintln!("IM_DIAGNOSTIC agent={} notification_missed", agent.as_str());
                        self.mark_modified(path, agent);
                    }
                } else {
                    self.open_new_session(path, agent);
                }
            }
        }
        let removed: Vec<_> = self
            .sessions
            .keys()
            .chain(self.baselines.keys())
            .filter(|path| !path.exists())
            .cloned()
            .collect();
        for path in removed {
            self.close_path(&path);
        }
        if self
            .roots
            .iter()
            .any(|root| root.watcher.is_none() && root.path.is_dir())
        {
            self.rescan_roots();
        }
    }

    fn rescan_roots(&mut self) {
        for index in 0..self.roots.len() {
            let kind = self.roots[index].kind;
            let path = self.roots[index].path.clone();

            if !path.is_dir() {
                self.roots[index].watcher = None;
                self.roots[index].status_watcher = None;
                self.status(kind, "directory_missing");
                continue;
            }

            if self.roots[index].watcher.is_none() {
                let inbound = self.inbound.clone();
                let overflow = Arc::clone(&self.overflow);
                let sink = move |event| {
                    if let Err(TrySendError::Full(_)) = inbound.try_send(Inbound::Change(event)) {
                        overflow.store(true, Ordering::Relaxed);
                    }
                };

                match FileObserver::watch(&path, sink) {
                    Ok(watcher) => self.roots[index].watcher = Some(watcher),
                    Err(_) => {
                        self.status(kind, "error");
                        continue;
                    }
                }
            }

            // Optional: unavailable when only the projects folder was granted.
            if self.roots[index].status_watcher.is_none()
                && let Some(dir) = claude_status_dir(kind, &path).filter(|dir| dir.is_dir())
            {
                let inbound = self.inbound.clone();
                let overflow = Arc::clone(&self.overflow);
                let sink = move |event| {
                    if let Err(TrySendError::Full(_)) = inbound.try_send(Inbound::Change(event)) {
                        overflow.store(true, Ordering::Relaxed);
                    }
                };
                self.roots[index].status_watcher = FileObserver::watch(&dir, sink).ok();
            }

            self.baseline_root(kind, &path);
            self.status(kind, "monitoring");
        }
    }

    fn baseline_root(&mut self, agent: AgentKind, root: &Path) {
        let mut candidates = discover_jsonl(root);
        candidates.sort_by_cached_key(|(_, metadata)| {
            std::cmp::Reverse(metadata.modified().unwrap_or(SystemTime::UNIX_EPOCH))
        });
        candidates.truncate(self.baseline_cap);

        // Oldest first, so the most recently modified files are evicted last.
        for (path, metadata) in candidates.into_iter().rev() {
            if self.sessions.contains_key(&path) || self.baselines.contains_key(&path) {
                continue;
            }

            self.insert_baseline(path, agent, FileCursor::baseline_from_metadata(&metadata));
        }
    }

    /// Records an EOF baseline. When the per-agent budget is full the least
    /// recently baselined file is forgotten, so a file that becomes active
    /// later can always be tracked.
    fn insert_baseline(&mut self, path: PathBuf, agent: AgentKind, cursor: FileCursor) {
        if self.baseline_counts[agent_index(agent)] >= self.baseline_cap {
            let oldest = self
                .baselines
                .iter()
                .filter(|(_, baseline)| baseline.agent == agent)
                .min_by_key(|(_, baseline)| baseline.touched)
                .map(|(path, _)| path.clone());
            if let Some(oldest) = oldest {
                self.take_baseline(&oldest);
            }
        }

        self.baseline_clock += 1;
        let baseline = Baseline {
            agent,
            cursor,
            touched: self.baseline_clock,
        };
        if let Some(previous) = self.baselines.insert(path, baseline) {
            self.baseline_counts[agent_index(previous.agent)] -= 1;
        }
        self.baseline_counts[agent_index(agent)] += 1;
    }

    fn take_baseline(&mut self, path: &Path) -> Option<Baseline> {
        let baseline = self.baselines.remove(path)?;
        self.baseline_counts[agent_index(baseline.agent)] -= 1;
        Some(baseline)
    }

    fn handle_change(&mut self, event: ChangeEvent) {
        for path in event.paths {
            if self.is_status_file(&path) {
                self.apply_status_file(&path);
                continue;
            }

            if path.extension().and_then(|value| value.to_str()) != Some("jsonl") {
                continue;
            }

            let Some(agent) = self.agent_for_path(&path) else {
                continue;
            };

            match event.kind {
                ChangeKind::Create => self.open_new_session(path, agent),
                ChangeKind::Modify => self.mark_modified(path, agent),
                ChangeKind::RemoveOrRename => self.close_path(&path),
                ChangeKind::Other => {}
            }
        }
    }

    fn open_new_session(&mut self, path: PathBuf, agent: AgentKind) {
        if let Some(session) = self.sessions.get_mut(&path) {
            session.dirty = true;
            return;
        }

        // FSEvents can report a creation flag for a file that already existed
        // when monitoring started. Its history must not be replayed.
        if let Some(baseline) = self.take_baseline(&path) {
            self.attach_baseline(path, baseline);
            return;
        }

        let Ok(file) = File::open(&path) else {
            return;
        };
        let Ok(metadata) = file.metadata() else {
            return;
        };

        let cursor = if self.existed_before_monitoring(&metadata) {
            FileCursor::baseline_from_metadata(&metadata)
        } else {
            match FileCursor::from_start(&file) {
                Ok(cursor) => cursor,
                Err(_) => return,
            }
        };
        self.insert_session(path, agent, file, cursor, true);
    }

    fn mark_modified(&mut self, path: PathBuf, agent: AgentKind) {
        let now = self.now();
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
                        session.interrupted_through = None;
                        session.parser = Parser::new(agent);
                        session.activity.apply(&NormalizedEvent::TurnEnd, now);
                        session.last_event_at = now;
                    }
                    Err(_) => {}
                }
            }
            return;
        }

        if let Some(baseline) = self.take_baseline(&path) {
            self.attach_baseline(path, baseline);
            return;
        }

        // Unknown pre-existing file: baseline at current EOF rather than replaying
        // historical content. A future append will be observed normally.
        if let Ok(metadata) = fs::metadata(&path) {
            if metadata.is_file() {
                self.insert_baseline(path, agent, FileCursor::baseline_from_metadata(&metadata));
            }
        }
    }

    fn attach_baseline(&mut self, path: PathBuf, baseline: Baseline) {
        let Ok(file) = File::open(&path) else {
            return;
        };
        let mut cursor = baseline.cursor;
        if cursor.refresh(&file).is_err() {
            return;
        }
        self.insert_session(path, baseline.agent, file, cursor, true);
    }

    fn existed_before_monitoring(&self, metadata: &Metadata) -> bool {
        metadata
            .created()
            .is_ok_and(|created| created + CREATION_SLACK < self.started_wall)
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
            activity: ActivityEngine::with_pending_timeout(
                now,
                match agent {
                    AgentKind::Claude => Duration::from_secs(120),
                    AgentKind::Codex => STALE_TURN_TIMEOUT,
                },
            ),
            dirty,
            interrupted_through: None,
            paused: false,
            last_event_at: now,
            last_phase: AgentState::Idle,
            last_emitted_intensity: 0.0,
            last_emit_at: None,
            unrecognized_records: Some(0),
            agent_version: None,
        };

        self.sessions.insert(path, session);
        self.with_writer(|writer| writer.session_opened(handle, agent));
    }

    fn evict_idle_session(&mut self) -> bool {
        let candidate = self
            .sessions
            .iter()
            // A paused session must stay tracked, or its next append would
            // reattach it unpaused and resume it without the user.
            .filter(|(_, session)| {
                !session.paused && session.activity.state().phase() == AgentState::Idle
            })
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
        self.take_baseline(path);
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
        let history_before_ms = wall_clock_ms().saturating_sub(HISTORY_AGE.as_millis() as i64);
        let Some(session) = self.sessions.get_mut(path) else {
            return;
        };

        let result = match scan_records(&mut session.file, &mut session.cursor, FILE_SCAN_BUDGET) {
            Ok(result) => result,
            Err(_) => {
                eprintln!("IM_DIAGNOSTIC session={} scan_error", session.handle);
                session.dirty = false;
                return;
            }
        };

        let mut unrecognized = false;
        for range in result.records {
            let parsed = match record_reader(&mut session.file, range) {
                Ok(reader) => session.parser.parse(reader),
                Err(_) => {
                    eprintln!("IM_DIAGNOSTIC session={} read_error", session.handle);
                    continue;
                }
            };

            session.cursor.commit_through(range.next_offset);

            let record = match parsed {
                Ok(record) => record,
                Err(error) => {
                    eprintln!(
                        "IM_DIAGNOSTIC session={} parse_error={:?} offset={}",
                        session.handle,
                        error.classify(),
                        range.start
                    );
                    unrecognized |= session.count_unrecognized(false);
                    continue;
                }
            };

            if let Some(version) = record
                .agent_version
                .as_deref()
                .map(sanitize_version)
                .filter(|version| !version.is_empty())
            {
                if session.agent_version.as_deref() != Some(version.as_str()) {
                    eprintln!(
                        "IM_DIAGNOSTIC session={} agent={} agent_version={}",
                        session.handle,
                        session.agent.as_str(),
                        version
                    );
                    session.agent_version = Some(version);
                }
            }

            if session.paused
                || session
                    .interrupted_through
                    .is_some_and(|offset| range.start < offset)
            {
                eprintln!(
                    "IM_DIAGNOSTIC session={} interrupted_record_ignored",
                    session.handle
                );
                continue;
            }

            let history = record
                .timestamp_ms
                .is_some_and(|written| written < history_before_ms);
            if !history && !record.quiet {
                unrecognized |= session.count_unrecognized(!record.events.is_empty());
            }
            for event in record.events {
                let kind = match &event {
                    NormalizedEvent::TurnStart => "turn_start",
                    NormalizedEvent::TurnEnd => "turn_end",
                    NormalizedEvent::ThinkingPulse { .. } => "thinking",
                    NormalizedEvent::WritingPulse { .. } => "writing",
                    NormalizedEvent::ToolStart { .. } => "tool_start",
                    NormalizedEvent::ToolEnd { .. } => "tool_end",
                    NormalizedEvent::UsagePulse { .. } => "usage",
                };
                eprintln!(
                    "IM_DIAGNOSTIC session={} agent={} event={} history={} accepted={} record_ms={:?}",
                    session.handle,
                    session.agent.as_str(),
                    kind,
                    history,
                    session.activity.state().accepts(&event),
                    record.timestamp_ms
                );
                if history {
                    session.activity.apply_history(&event);
                } else {
                    session.activity.apply(&event, now);
                    session.last_event_at = now;
                }
            }
        }

        let eof = session
            .file
            .seek(io::SeekFrom::End(0))
            .unwrap_or(session.cursor.scan_offset());
        session.dirty = session.cursor.scan_offset() < eof;

        if unrecognized {
            let agent = session.agent;
            eprintln!(
                "IM_DIAGNOSTIC session={} agent={} unrecognized_format",
                session.handle,
                agent.as_str()
            );
            self.with_writer(|writer| writer.error("warning", "PARSE3006", agent.as_str(), true));
        }
    }

    fn expire_stale_turns(&mut self) {
        let now = self.now();
        for session in self.sessions.values_mut() {
            if session.activity.expire_stale_turn(now, STALE_TURN_TIMEOUT) {
                eprintln!("IM_DIAGNOSTIC session={} stale_timeout", session.handle);
            }
        }
    }

    /// Emits phase changes immediately and intensity updates at most every
    /// `ACTIVITY_INTERVAL` per session. Once a session falls silent a single
    /// zero-intensity update is sent and the session stops emitting.
    fn emit_activity(&mut self) {
        let now = self.now();

        let samples: Vec<_> = self
            .sessions
            .values_mut()
            .filter_map(|session| {
                let mut sample = session.activity.sample(now);
                if sample.intensity < ACTIVITY_EPSILON {
                    sample.intensity = 0.0;
                }

                let phase_changed = sample.phase != session.last_phase;
                let audible = sample.intensity > 0.0 || session.last_emitted_intensity > 0.0;
                let due = session
                    .last_emit_at
                    .is_none_or(|at| now.saturating_sub(at) >= ACTIVITY_INTERVAL);
                if !phase_changed && !(audible && due) {
                    return None;
                }

                session.last_phase = sample.phase;
                session.last_emitted_intensity = sample.intensity;
                session.last_emit_at = Some(now);
                Some((
                    session.handle,
                    session.agent,
                    sample,
                    session.mutation_tool(),
                ))
            })
            .collect();

        for (handle, agent, sample, tool_class) in samples {
            self.with_writer(|writer| writer.activity(handle, agent, sample, tool_class));
        }
    }

    fn is_status_file(&self, path: &Path) -> bool {
        path.extension().is_some_and(|ext| ext == "json")
            && self
                .roots
                .iter()
                .any(|root| claude_status_dir(root.kind, &root.path).as_deref() == path.parent())
    }

    /// Claude Code writes no transcript record when the user presses Esc
    /// before the model has produced output, but its status file flips to
    /// `idle`. Closes the turn of that session and of its subagents, whose
    /// transcripts live under a directory named after the session id.
    fn apply_status_file(&mut self, path: &Path) {
        #[derive(serde::Deserialize)]
        struct StatusFile {
            #[serde(rename = "sessionId")]
            session_id: String,
            status: Option<String>,
        }

        // Read the current content rather than trusting the event: a late
        // notification must not end a turn the user has already restarted.
        let Ok(file) = File::open(path) else {
            return;
        };
        let Ok(status) = serde_json::from_reader::<_, StatusFile>(file.take(MAX_STATUS_FILE_BYTES))
        else {
            return;
        };
        if status.status.as_deref() != Some("idle") {
            return;
        }

        let id = status.session_id.as_str();
        let matching: Vec<_> = self
            .sessions
            .iter()
            .filter(|(transcript, session)| {
                session.agent == AgentKind::Claude
                    && (transcript.file_stem().is_some_and(|stem| stem == id)
                        || transcript.iter().any(|part| part == id))
            })
            .map(|(transcript, _)| transcript.clone())
            .collect();

        for transcript in matching {
            let now = self.now();
            if let Some(session) = self.sessions.get_mut(&transcript) {
                // An idle session has nothing to interrupt. Its status file can
                // still read `idle` just after a new prompt row was written, and
                // a cutoff then would swallow that prompt's TurnStart.
                if session.activity.state().phase() == AgentState::Idle {
                    continue;
                }
                // Keep normal scan budgets. A cutoff also covers incomplete
                // records that finish after this notification.
                let Ok(metadata) = session.file.metadata() else {
                    continue;
                };
                session.interrupted_through = Some(metadata.len());
                session.activity.apply(&NormalizedEvent::TurnEnd, now);
                session.last_event_at = now;
            }
        }
    }

    fn agent_for_path(&self, path: &Path) -> Option<AgentKind> {
        self.roots
            .iter()
            .find(|root| path.starts_with(&root.path))
            .map(|root| root.kind)
    }

    fn now(&self) -> Duration {
        let now = self.started.elapsed();
        #[cfg(test)]
        let now = now + self.clock_skew;
        now
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

/// Keeps a transcript-supplied version safe to print on one diagnostic line.
fn sanitize_version(raw: &str) -> String {
    raw.chars()
        .filter(|c| c.is_ascii_alphanumeric() || matches!(c, '.' | '-' | '+' | '_'))
        .take(32)
        .collect()
}

fn wall_clock_ms() -> i64 {
    SystemTime::now()
        .duration_since(SystemTime::UNIX_EPOCH)
        .map_or(0, |since| since.as_millis() as i64)
}

fn agent_index(agent: AgentKind) -> usize {
    match agent {
        AgentKind::Claude => 0,
        AgentKind::Codex => 1,
    }
}

fn discover_jsonl(root: &Path) -> Vec<(PathBuf, Metadata)> {
    // ponytail: capped traversal; rotate scan batches if large archives need notification-free monitoring.
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
            if visited >= MAX_DISCOVERY_ENTRIES {
                break;
            }
            visited += 1;

            let path = entry.path();
            let Ok(metadata) = entry.metadata() else {
                continue;
            };

            if metadata.is_dir() {
                stack.push(path);
            } else if metadata.is_file()
                && path.extension().and_then(|value| value.to_str()) == Some("jsonl")
            {
                found.push((path, metadata));
            }
        }
    }

    found
}

/// `~/.claude/sessions` next to a Claude `~/.claude/projects` root.
fn claude_status_dir(agent: AgentKind, root: &Path) -> Option<PathBuf> {
    if agent != AgentKind::Claude || root.file_name()? != "projects" {
        return None;
    }
    Some(root.parent()?.join("sessions"))
}

/// A disabled agent simply gets no roots.
fn resolve_root_grants(agent: AgentKind, grants: Vec<RootGrant>, enabled: bool) -> Vec<AgentRoot> {
    grants
        .into_iter()
        .filter(|_| enabled)
        .take(MAX_CONFIGURED_ROOTS_PER_AGENT)
        .filter_map(|grant| {
            if let Some(bookmark) = grant.bookmark {
                let scope = resolve_transfer_bookmark(&bookmark).ok()?;
                return Some(AgentRoot {
                    kind: agent,
                    path: scope.path().to_path_buf(),
                    watcher: None,
                    status_watcher: None,
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
                watcher: None,
                status_watcher: None,
                _scope: None,
            })
        })
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::io::Write;
    use std::sync::atomic::AtomicU64;

    static NEXT_ROOT: AtomicU64 = AtomicU64::new(0);

    #[derive(Clone, Default)]
    struct SharedOutput(Arc<Mutex<Vec<u8>>>);

    impl io::Write for SharedOutput {
        fn write(&mut self, bytes: &[u8]) -> io::Result<usize> {
            self.0.lock().unwrap().extend_from_slice(bytes);
            Ok(bytes.len())
        }

        fn flush(&mut self) -> io::Result<()> {
            Ok(())
        }
    }

    impl SharedOutput {
        fn take_messages(&self) -> Vec<serde_json::Value> {
            let bytes = std::mem::take(&mut *self.0.lock().unwrap());
            bytes
                .split(|byte| *byte == b'\n')
                .filter(|line| !line.is_empty())
                .map(|line| serde_json::from_slice(line).unwrap())
                .collect()
        }

        fn take_activity(&self) -> Vec<serde_json::Value> {
            self.take_messages()
                .into_iter()
                .filter(|message| message["type"] == "activity")
                .collect()
        }
    }

    struct Fixture {
        root: PathBuf,
        output: SharedOutput,
        runtime: MonitorRuntime<SharedOutput>,
        _inbound: Receiver<Inbound>,
    }

    impl Fixture {
        fn new() -> Self {
            let root = std::env::temp_dir().join(format!(
                "im-thinking-runtime-fixture-{}-{}",
                std::process::id(),
                NEXT_ROOT.fetch_add(1, Ordering::Relaxed)
            ));
            let _ = fs::remove_dir_all(&root);
            fs::create_dir_all(&root).unwrap();
            Self::with_root(root)
        }

        fn with_root(root: PathBuf) -> Self {
            let output = SharedOutput::default();
            let writer = Arc::new(Mutex::new(ServerWriter::new(output.clone())));
            let (tx, rx) = mpsc::sync_channel(MAX_ACTIVITY_QUEUE);
            let roots = AgentRoots {
                claude: vec![RootGrant {
                    path: Some(root.to_string_lossy().into_owned()),
                    bookmark: None,
                }],
                codex: Vec::new(),
            };
            let flags = AgentFlags {
                claude: true,
                codex: false,
            };

            Self {
                runtime: MonitorRuntime::new(writer, flags, roots, tx),
                root,
                output,
                _inbound: rx,
            }
        }

        fn path(&self, name: &str) -> PathBuf {
            self.root.join(name)
        }

        fn change(&mut self, kind: ChangeKind, path: &Path) {
            self.runtime.handle_change(ChangeEvent {
                kind,
                paths: vec![path.to_path_buf()],
            });
            self.runtime.process_dirty_sessions();
            self.runtime.expire_stale_turns();
            self.runtime.emit_activity();
        }

        fn advance(&mut self, by: Duration) {
            self.runtime.clock_skew += by;
            self.runtime.expire_stale_turns();
            self.runtime.emit_activity();
        }

        fn session(&self, path: &Path) -> &Session {
            self.runtime.sessions.get(path).unwrap()
        }
    }

    impl Drop for Fixture {
        fn drop(&mut self) {
            let _ = fs::remove_dir_all(&self.root);
        }
    }

    fn append(path: &Path, line: &str) {
        let mut file = fs::OpenOptions::new()
            .create(true)
            .append(true)
            .open(path)
            .unwrap();
        writeln!(file, "{line}").unwrap();
    }

    const USER_TURN: &str = r#"{"type":"user","message":{"content":"x"}}"#;
    const THINKING: &str = r#"{"type":"assistant","message":{"content":[{"type":"thinking"}]}}"#;

    #[test]
    fn paused_session_ignores_activity_until_manual_resume_without_replaying_backlog() {
        let mut fixture = Fixture::new();
        let path = fixture.path("paused.jsonl");
        append(&path, USER_TURN);
        fixture.change(ChangeKind::Create, &path);
        append(&path, USER_TURN);
        fixture.change(ChangeKind::Modify, &path);
        let handle = fixture.session(&path).handle;
        fixture
            .runtime
            .handle_command(MonitorCommand::SetSessionPaused {
                session: handle,
                paused: true,
            });
        append(&path, THINKING);
        fixture.change(ChangeKind::Modify, &path);
        assert!(fixture.session(&path).paused);
        assert_eq!(
            fixture.session(&path).activity.state().phase(),
            AgentState::Idle
        );
        let other = fixture.path("other.jsonl");
        append(&other, USER_TURN);
        fixture.change(ChangeKind::Create, &other);
        append(&other, USER_TURN);
        fixture.change(ChangeKind::Modify, &other);
        assert_eq!(
            fixture.session(&other).activity.state().phase(),
            AgentState::Thinking
        );
        // An append without a notification must not replay on resume.
        append(&path, USER_TURN);
        fixture
            .runtime
            .handle_command(MonitorCommand::SetSessionPaused {
                session: handle,
                paused: false,
            });
        fixture.change(ChangeKind::Modify, &path);
        assert!(!fixture.session(&path).paused);
        assert_eq!(
            fixture.session(&path).activity.state().phase(),
            AgentState::Idle
        );
        append(&path, THINKING);
        fixture.change(ChangeKind::Modify, &path);
        assert_eq!(
            fixture.session(&path).activity.state().phase(),
            AgentState::Thinking
        );
    }

    #[test]
    fn paused_session_is_not_evicted_at_the_session_cap() {
        let mut fixture = Fixture::new();
        let paused = fixture.path("paused.jsonl");
        append(&paused, USER_TURN);
        fixture.change(ChangeKind::Create, &paused);
        let handle = fixture.session(&paused).handle;
        fixture
            .runtime
            .handle_command(MonitorCommand::SetSessionPaused {
                session: handle,
                paused: true,
            });
        for i in 0..MAX_ACTIVE_SESSIONS {
            fixture.advance(Duration::from_millis(1));
            let path = fixture.path(&format!("idle-{i}.jsonl"));
            std::fs::write(&path, "").unwrap();
            fixture.change(ChangeKind::Create, &path);
        }
        assert_eq!(fixture.runtime.sessions.len(), MAX_ACTIVE_SESSIONS);
        assert!(fixture.session(&paused).paused);
    }

    #[test]
    fn reconciliation_detects_codex_appends_without_notifications() {
        let mut fixture = Fixture::new();
        fixture.runtime.roots[0].kind = AgentKind::Codex;
        let path = fixture.path("codex.jsonl");
        append(
            &path,
            r#"{"type":"event_msg","payload":{"type":"task_started"}}"#,
        );
        fixture.runtime.rescan_roots();
        fixture.runtime.reconcile_files();
        fixture.runtime.process_dirty_sessions();
        assert!(!fixture.runtime.sessions.contains_key(&path));

        append(
            &path,
            r#"{"type":"event_msg","payload":{"type":"task_started"}}"#,
        );
        fixture.runtime.reconcile_files();
        fixture.runtime.process_dirty_sessions();
        fixture.runtime.emit_activity();
        assert_eq!(
            fixture.session(&path).activity.state().phase(),
            AgentState::Thinking
        );

        append(
            &path,
            r#"{"type":"event_msg","payload":{"type":"task_complete"}}"#,
        );
        fixture.runtime.reconcile_files();
        fixture.runtime.process_dirty_sessions();
        fixture.runtime.emit_activity();
        assert_eq!(
            fixture.session(&path).activity.state().phase(),
            AgentState::Idle
        );
        assert_eq!(
            fixture.output.take_activity().last().unwrap()["phase"],
            "idle"
        );
        fs::remove_file(&path).unwrap();
        fixture.runtime.reconcile_files();
        assert!(fixture.runtime.sessions.is_empty());
    }

    #[test]
    fn reconciliation_discovers_new_session_without_replaying_existing_history() {
        let mut fixture = Fixture::new();
        let path = fixture.path("new.jsonl");
        append(&path, USER_TURN);
        fixture.runtime.reconcile_files();
        fixture.runtime.process_dirty_sessions();
        assert_eq!(
            fixture.session(&path).activity.state().phase(),
            AgentState::Thinking
        );
    }

    #[test]
    fn replaced_transcript_clears_old_activity_and_parser_state() {
        let mut fixture = Fixture::new();
        let path = fixture.path("replace.jsonl");
        append(&path, USER_TURN);
        fixture.change(ChangeKind::Create, &path);
        assert_eq!(
            fixture.session(&path).activity.state().phase(),
            AgentState::Thinking
        );
        let replacement = fixture.path("replacement.tmp");
        fs::write(&replacement, b"{}\n").unwrap();
        fs::rename(replacement, &path).unwrap();
        fixture.runtime.reconcile_files();
        fixture.runtime.process_dirty_sessions();
        fixture.runtime.emit_activity();
        assert_eq!(
            fixture.session(&path).activity.state().phase(),
            AgentState::Idle
        );
        append(&path, USER_TURN);
        fixture.change(ChangeKind::Modify, &path);
        assert_eq!(
            fixture.session(&path).activity.state().phase(),
            AgentState::Thinking
        );
    }

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

    #[test]
    fn file_outside_baseline_budget_is_tracked_once_it_is_appended_to() {
        let mut fixture = Fixture::new();
        fixture.runtime.baseline_cap = 2;
        let old = fixture.path("old.jsonl");
        append(&old, USER_TURN);
        std::thread::sleep(Duration::from_millis(20));
        append(&fixture.path("b.jsonl"), USER_TURN);
        append(&fixture.path("c.jsonl"), USER_TURN);
        fixture.runtime.rescan_roots();
        assert!(!fixture.runtime.baselines.contains_key(&old));

        // The first append only establishes a baseline; later appends are observed.
        append(&old, USER_TURN);
        fixture.change(ChangeKind::Modify, &old);
        append(&old, USER_TURN);
        fixture.change(ChangeKind::Modify, &old);

        assert!(fixture.runtime.sessions.contains_key(&old));
        assert_eq!(
            fixture.session(&old).activity.state().phase(),
            AgentState::Thinking
        );
        assert!(fixture.runtime.baseline_counts[0] <= 2);
    }

    #[test]
    fn create_event_for_baselined_file_does_not_replay_history() {
        let mut fixture = Fixture::new();
        let path = fixture.path("existing.jsonl");
        append(&path, USER_TURN);
        append(&path, THINKING);
        fixture.runtime.rescan_roots();

        fixture.change(ChangeKind::Create, &path);

        let session = fixture.session(&path);
        assert_eq!(
            session.cursor.committed_offset(),
            fs::metadata(&path).unwrap().len()
        );
        assert_eq!(session.activity.state().phase(), AgentState::Idle);
    }

    #[test]
    fn create_event_for_file_older_than_monitoring_does_not_replay_history() {
        let root = std::env::temp_dir().join(format!(
            "im-thinking-runtime-preexisting-{}",
            std::process::id()
        ));
        let _ = fs::remove_dir_all(&root);
        fs::create_dir_all(&root).unwrap();
        let path = root.join("preexisting.jsonl");
        append(&path, USER_TURN);
        if fs::metadata(&path).unwrap().created().is_err() {
            // Creation time is unavailable on this filesystem.
            let _ = fs::remove_dir_all(&root);
            return;
        }
        std::thread::sleep(CREATION_SLACK + Duration::from_millis(100));

        // Not baselined (no rescan), but created before the runtime started.
        let mut fixture = Fixture::with_root(root);
        fixture.change(ChangeKind::Create, &path);

        assert_eq!(
            fixture.session(&path).activity.state().phase(),
            AgentState::Idle
        );
    }

    fn format_warnings(output: &SharedOutput) -> usize {
        output
            .take_messages()
            .iter()
            .filter(|message| message["code"] == "PARSE3006")
            .count()
    }

    #[test]
    fn quiet_records_observed_mid_turn_are_not_reported() {
        let mut fixture = Fixture::new();
        let path = fixture.path("subagent.jsonl");
        for _ in 0..UNRECOGNIZED_FORMAT_RECORDS * 2 {
            append(&path, r#"{"type":"progress"}"#);
        }

        fixture.change(ChangeKind::Create, &path);

        assert_eq!(format_warnings(&fixture.output), 0);
    }

    #[test]
    fn unrecognized_transcript_format_is_reported_once() {
        let mut fixture = Fixture::new();
        let path = fixture.path("future.jsonl");
        for _ in 0..UNRECOGNIZED_FORMAT_RECORDS * 2 {
            append(
                &path,
                r#"{"type":"model_output","body":[{"kind":"reasoning"}]}"#,
            );
        }

        fixture.change(ChangeKind::Create, &path);

        assert_eq!(format_warnings(&fixture.output), 1);
    }

    #[test]
    fn recognized_transcript_format_is_not_reported() {
        let mut fixture = Fixture::new();
        let path = fixture.path("current.jsonl");
        append(&path, USER_TURN);
        for _ in 0..UNRECOGNIZED_FORMAT_RECORDS * 2 {
            append(&path, r#"{"type":"progress"}"#);
        }

        fixture.change(ChangeKind::Create, &path);

        assert_eq!(format_warnings(&fixture.output), 0);
    }

    #[test]
    fn new_file_is_observed_from_its_first_byte() {
        let mut fixture = Fixture::new();
        let path = fixture.path("new.jsonl");
        append(&path, USER_TURN);

        fixture.change(ChangeKind::Create, &path);

        assert_eq!(
            fixture.session(&path).activity.state().phase(),
            AgentState::Thinking
        );
    }

    #[test]
    fn open_turn_without_new_signal_stops_emitting() {
        let mut fixture = Fixture::new();
        let path = fixture.path("interrupted.jsonl");
        append(&path, USER_TURN);
        fixture.change(ChangeKind::Create, &path);
        assert!(!fixture.output.take_activity().is_empty());

        // Pending model output holds activity for up to two minutes.
        for _ in 0..1300 {
            fixture.advance(ACTIVITY_INTERVAL);
        }
        let settled = fixture.output.take_activity();
        assert_eq!(settled.last().unwrap()["intensity"], 0.0);

        for _ in 0..20 {
            fixture.advance(ACTIVITY_INTERVAL);
        }
        assert!(fixture.output.take_activity().is_empty());
        let session = fixture.session(&path);
        assert_eq!(session.activity.state().phase(), AgentState::Thinking);
        assert!(session.next_wakeup(fixture.runtime.now()) > Some(Duration::from_secs(60)));
    }

    #[test]
    fn stale_turn_is_closed_and_reported_idle() {
        let mut fixture = Fixture::new();
        let path = fixture.path("stale.jsonl");
        append(&path, USER_TURN);
        fixture.change(ChangeKind::Create, &path);
        fixture.output.take_messages();

        fixture.advance(STALE_TURN_TIMEOUT);

        let activity = fixture.output.take_activity();
        assert_eq!(activity.len(), 1);
        assert_eq!(activity[0]["phase"], "idle");
        assert_eq!(
            fixture.session(&path).next_wakeup(fixture.runtime.now()),
            None
        );
        assert!(fixture.runtime.next_wakeup().unwrap() <= RECONCILE_INTERVAL);
    }

    #[test]
    fn idle_status_file_closes_turn_interrupted_before_output() {
        let base = std::env::temp_dir().join(format!(
            "im-thinking-status-fixture-{}-{}",
            std::process::id(),
            NEXT_ROOT.fetch_add(1, Ordering::Relaxed)
        ));
        let _ = fs::remove_dir_all(&base);
        let sessions = base.join("sessions");
        fs::create_dir_all(base.join("projects/p")).unwrap();
        fs::create_dir_all(&sessions).unwrap();
        let mut fixture = Fixture::with_root(base.join("projects"));

        let main = fixture.path("p/abc.jsonl");
        let subagent = fixture.path("p/abc/subagents/agent-1.jsonl");
        let other = fixture.path("p/xyz.jsonl");
        fs::create_dir_all(subagent.parent().unwrap()).unwrap();
        for path in [&main, &subagent, &other] {
            append(path, USER_TURN);
            fixture.change(ChangeKind::Create, path);
        }

        let status = sessions.join("123.json");
        fs::write(&status, r#"{"pid":123,"sessionId":"abc","status":"busy"}"#).unwrap();
        fixture.change(ChangeKind::Modify, &status);
        assert_eq!(
            fixture.session(&main).activity.state().phase(),
            AgentState::Thinking
        );

        // Esc while thinking: no transcript record, only the status flips.
        fs::write(&status, r#"{"pid":123,"sessionId":"abc","status":"idle"}"#).unwrap();
        fixture.change(ChangeKind::Modify, &status);
        assert_eq!(
            fixture.session(&main).activity.state().phase(),
            AgentState::Idle
        );
        assert_eq!(
            fixture.session(&subagent).activity.state().phase(),
            AgentState::Idle
        );
        assert_eq!(
            fixture.session(&other).activity.state().phase(),
            AgentState::Thinking
        );

        // Fixture's Drop only removes projects/; base also holds sessions/.
        drop(fixture);
        let _ = fs::remove_dir_all(&base);
    }

    #[test]
    fn restored_history_updates_state_without_emitting_activity() {
        let mut fixture = Fixture::new();
        let path = fixture.path("restored.jsonl");
        // A rollout materialized from an archive: complete, old records.
        append(
            &path,
            r#"{"type":"user","timestamp":"2020-01-01T00:00:00Z","message":{"content":"x"}}"#,
        );
        append(
            &path,
            r#"{"type":"assistant","timestamp":"2020-01-01T00:00:05Z","message":{"content":[{"type":"thinking"}]}}"#,
        );

        fixture.change(ChangeKind::Create, &path);
        for _ in 0..20 {
            fixture.advance(ACTIVITY_INTERVAL);
        }

        assert!(
            fixture
                .output
                .take_activity()
                .iter()
                .all(|message| message["intensity"] == 0.0)
        );
        assert!(!fixture.session(&path).activity.state().awaiting_model());
    }

    #[test]
    fn idle_status_does_not_swallow_a_prompt_written_while_idle() {
        let mut fixture = Fixture::new();
        let path = fixture.path("abc.jsonl");
        append(&path, USER_TURN);
        append(&path, r#"{"type":"system","subtype":"turn_duration"}"#);
        fixture.change(ChangeKind::Create, &path);
        assert_eq!(
            fixture.session(&path).activity.state().phase(),
            AgentState::Idle
        );

        // The next prompt lands before the status file flips to busy.
        append(&path, USER_TURN);
        let status = fixture.path("status.json");
        fs::write(&status, r#"{"sessionId":"abc","status":"idle"}"#).unwrap();
        fixture.runtime.apply_status_file(&status);
        fixture.change(ChangeKind::Modify, &path);

        assert_eq!(
            fixture.session(&path).activity.state().phase(),
            AgentState::Thinking
        );
    }

    #[test]
    fn idle_status_cutoff_covers_scan_budgets_and_partial_rows() {
        let mut fixture = Fixture::new();
        let path = fixture.path("abc.jsonl");
        append(&path, USER_TURN);
        fixture.change(ChangeKind::Create, &path);
        fixture.output.take_messages();

        // More than both the byte and record budgets, followed by a partial row.
        for _ in 0..3000 {
            append(&path, USER_TURN);
        }
        append(
            &path,
            &format!(r#"{{"ignored":"{}"}}"#, "x".repeat(FILE_SCAN_BUDGET)),
        );
        let mut file = fs::OpenOptions::new().append(true).open(&path).unwrap();
        write!(file, r#"{{"type":"user","message":{{"content":""#).unwrap();

        let status = fixture.path("status.json");
        fs::write(&status, r#"{"sessionId":"abc","status":"idle"}"#).unwrap();
        fixture.runtime.apply_status_file(&status);
        fixture.runtime.sessions.get_mut(&path).unwrap().dirty = true;
        let mut scans = 0;
        while fixture.session(&path).dirty {
            fixture.runtime.process_dirty_sessions();
            fixture.runtime.emit_activity();
            assert_eq!(
                fixture.session(&path).activity.state().phase(),
                AgentState::Idle
            );
            scans += 1;
            assert!(scans < 20);
        }
        assert!(scans > 1);

        // Completing the interrupted row later must still stay silent.
        writeln!(file, r#"x"}}}}"#).unwrap();
        fixture.change(ChangeKind::Modify, &path);
        assert_eq!(
            fixture.session(&path).activity.state().phase(),
            AgentState::Idle
        );
        assert!(
            fixture
                .output
                .take_activity()
                .iter()
                .all(|m| m["intensity"] == 0.0)
        );

        // A genuinely new prompt beyond the cutoff starts a new turn.
        append(&path, USER_TURN);
        fixture.change(ChangeKind::Modify, &path);
        fixture.advance(ACTIVITY_INTERVAL);
        assert_eq!(
            fixture.session(&path).activity.state().phase(),
            AgentState::Thinking
        );
        assert!(
            fixture
                .output
                .take_activity()
                .iter()
                .any(|m| m["intensity"].as_f64().unwrap() > 0.06)
        );
    }

    #[test]
    fn codex_long_turn_finishes_without_late_records_reopening_it() {
        let mut fixture = Fixture::new();
        fixture.runtime.roots[0].kind = AgentKind::Codex;
        let path = fixture.path("codex.jsonl");
        append(
            &path,
            r#"{"type":"event_msg","payload":{"type":"task_started"}}"#,
        );
        fixture.change(ChangeKind::Create, &path);
        fixture.advance(Duration::from_secs(180));
        assert!(
            fixture
                .output
                .take_activity()
                .iter()
                .any(|m| m["intensity"].as_f64().unwrap() > 0.06)
        );

        append(
            &path,
            r#"{"type":"event_msg","payload":{"type":"task_complete"}}"#,
        );
        fixture.change(ChangeKind::Modify, &path);
        append(
            &path,
            r#"{"type":"event_msg","payload":{"type":"item_completed","item":{"type":"AgentMessage"}}}"#,
        );
        fixture.change(ChangeKind::Modify, &path);
        assert_eq!(
            fixture.session(&path).activity.state().phase(),
            AgentState::Idle
        );
        assert!(
            fixture
                .output
                .take_activity()
                .iter()
                .all(|m| m["phase"] == "idle" && m["intensity"] == 0.0)
        );
        fixture.advance(SIGNAL_SETTLE);
        assert_eq!(
            fixture.session(&path).next_wakeup(fixture.runtime.now()),
            None
        );
        assert!(fixture.runtime.next_wakeup().unwrap() <= RECONCILE_INTERVAL);
    }

    #[test]
    fn activity_is_rate_limited_per_session() {
        let mut fixture = Fixture::new();
        let path = fixture.path("busy.jsonl");
        append(&path, USER_TURN);
        fixture.change(ChangeKind::Create, &path);
        fixture.output.take_messages();

        for _ in 0..20 {
            append(&path, THINKING);
            fixture.change(ChangeKind::Modify, &path);
        }

        assert!(fixture.output.take_activity().len() <= 1);
    }
}
