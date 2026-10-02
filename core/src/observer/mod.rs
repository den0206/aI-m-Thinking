use std::path::{Path, PathBuf};
use std::sync::mpsc::Sender;

use notify::{Event, EventKind, RecommendedWatcher, RecursiveMode, Watcher};

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ChangeKind {
    Create,
    Modify,
    RemoveOrRename,
    Other,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ChangeEvent {
    pub kind: ChangeKind,
    pub paths: Vec<PathBuf>,
}

pub struct FileObserver {
    _watcher: RecommendedWatcher,
}

impl FileObserver {
    /// Watches a root recursively using notify's recommended native backend.
    /// On macOS notify uses FSEvents with its default features.
    pub fn watch(root: &Path, sender: Sender<ChangeEvent>) -> notify::Result<Self> {
        let mut watcher = notify::recommended_watcher(move |result: notify::Result<Event>| {
            let Ok(event) = result else {
                return;
            };

            let kind = match event.kind {
                EventKind::Create(_) => ChangeKind::Create,
                EventKind::Modify(_) => ChangeKind::Modify,
                EventKind::Remove(_) => ChangeKind::RemoveOrRename,
                _ => ChangeKind::Other,
            };

            let _ = sender.send(ChangeEvent {
                kind,
                paths: event.paths,
            });
        })?;

        watcher.watch(root, RecursiveMode::Recursive)?;
        Ok(Self { _watcher: watcher })
    }
}
