# Mac App Store Readiness

This document is the source of truth for the Mac App Store path. The direct Developer ID / DMG distribution path remains separate and must continue to work.

Submission steps and the remaining checklist (Japanese): [APP_STORE_SUBMISSION_JP.md](APP_STORE_SUBMISSION_JP.md).

## Current position

The Mac App Store path is technically realistic, but it is not yet submission-ready.

Implemented now:

- App Store distribution mode separated from direct distribution
- App Sandbox entitlements for the main app
- sandbox inheritance entitlements for the bundled Rust helper
- user-selected read-only folder access only
- persistent security-scoped bookmarks stored by the Swift app
- implicit/transfer bookmark handoff to the Rust helper
- bounded bookmark/root grants over existing IPC
- no hardcoded HOME lookup inside the Rust Core
- App Store folder authorization UI for Claude Code and Codex
- privacy manifest bundled with the app
- CI-only `appstore-smoke` bundle with entitlement verification

Still required before submission:

- on-device sandbox smoke test with real Claude Code and Codex folders
- real Xcode macOS App target / Archive path for Mac App Store packaging
- Apple Distribution / Mac Installer Distribution signing configuration
- App Store Connect app record and metadata
- App Store privacy answers validated against the final binary
- TestFlight / internal App Store Connect validation
- final Review Notes and reviewer reproduction steps
- actual App Review submission

Apple requires Mac App Store apps to be appropriately sandboxed and packaged/submitted using Xcode technologies. The hand-built app bundle remains for direct distribution and CI smoke testing, not as the final App Store submission artifact.

Apple references:

- https://developer.apple.com/app-store/review/guidelines/
- https://developer.apple.com/documentation/security/app-sandbox/
- https://developer.apple.com/documentation/security/accessing-files-from-the-macos-app-sandbox
- https://developer.apple.com/documentation/security/embedding-a-command-line-tool-in-a-sandboxed-app
- https://developer.apple.com/documentation/bundleresources/privacy-manifest-files

## Distribution architecture

```text
Shared Swift UI + Rust parser/activity core
            |
       DistributionMode
       /              \
 direct                 app-store
   |                        |
DirectAgentRootProvider     SandboxAgentRootProvider
   |                        |
path grants                 NSOpenPanel user consent
   |                        |
Rust observer               persistent security-scoped bookmark
                            |
                            implicit transfer bookmark
                            |
                            sandboxed Rust helper
```

Direct mode keeps the existing zero-setup behavior:

```text
~/.claude/projects
~/.codex/sessions
```

App Store mode does not automatically traverse those locations. The user explicitly chooses each folder.

## User consent flow

For each supported agent:

1. On first launch a welcome window shows Claude Code / Codex authorization state; it stays open until at least one folder is allowed or the user quits. Later, the menu's `Agent Folder Access` shows the same state.
2. User chooses `Choose Folder…`.
3. `NSOpenPanel` requests a directory.
4. The app checks the folder looks like that agent's session folder (named `projects` / `sessions`, not the other agent's layout). Otherwise it shows a red error under that agent and saves nothing.
5. The app creates a read-only security-scoped bookmark.
6. Only bookmark data is persisted in the app's UserDefaults container.
7. At monitor start, the app resolves the bookmark and refreshes it if stale.
8. A transfer bookmark is sent to the Rust helper over bounded IPC.
9. The helper resolves the bookmark and keeps the resulting sandbox extension only for the monitor lifetime.
10. Revoke removes the persisted bookmark and restarts the monitor.

Paths selected by the user are not persisted as a second app-owned database.

## Main app entitlements

`app/Resources/AImThinking.appstore.entitlements`:

```text
com.apple.security.app-sandbox = true
com.apple.security.files.user-selected.read-only = true
com.apple.security.files.bookmarks.app-scope = true
```

The app does not request:

- Full Disk Access
- Accessibility
- Input Monitoring
- Screen Recording
- user-selected read/write access
- root privileges
- setuid

## Rust helper entitlements

`app/Resources/im-thinking-core.appstore.entitlements`:

```text
com.apple.security.app-sandbox = true
com.apple.security.inherit = true
```

The helper deliberately does not receive broad file entitlements. User-granted dynamic access is transferred by bookmark.

## Privacy manifest

`app/Resources/PrivacyInfo.xcprivacy` declares:

- tracking: false
- collected data types: none
- UserDefaults required-reason usage for app-owned preferences/bookmarks

The current product does not upload prompt, response, reasoning, source code, tool payloads, or session JSONL to a server.

Before submission, generate/review Xcode's privacy report against the final Archive. If final code or dependencies change, re-check the manifest and App Store Connect privacy answers.

## App Store smoke build

This is a CI/development validation bundle only:

```bash
CONFIG=appstore-smoke ./scripts/build-app.sh
```

Output:

```text
.build/appstore-smoke/aI'm Thinking App Store Smoke.app
```

CI verifies:

- distribution mode is `app-store`
- main app has App Sandbox
- main app has user-selected read-only
- helper has App Sandbox
- helper has `inherit`
- helper does not have user-selected file entitlement
- PrivacyInfo.xcprivacy is bundled

Do not upload this manually assembled smoke app to App Store Connect.

## Xcode submission target — remaining work

Apple Review Guideline 2.4.5 requires the Mac App Store app to be packaged and submitted using Xcode technologies.

Before submission, add a real macOS App target that:

- references the existing Swift sources rather than duplicating them
- embeds the existing Rust release helper in the app bundle
- signs the helper with sandbox + inherit entitlements
- signs the app with the App Store sandbox entitlements
- bundles PrivacyInfo.xcprivacy
- uses the production bundle identifier `com.den0206.AImThinking` (or the final registered identifier)
- supports Product > Archive
- exports/uploads using the Mac App Store / App Store Connect distribution path

Do not replace the direct build script; the two distribution paths intentionally coexist.

## Review Notes draft

Suggested technical explanation for App Review:

> aI'm Thinking is a local menu-bar utility that provides optional typing sounds while supported AI coding tools are working. The app does not modify Claude Code or Codex. It does not install plugins, shell hooks, or background daemons. To detect activity, the user explicitly grants read-only access to the local session folder for each tool using the standard macOS open panel. Access is stored as a security-scoped bookmark and can be revoked from the app. Session content is processed locally; prompts, responses, source code, reasoning content, and tool payloads are not uploaded or persisted by aI'm Thinking.

Reviewer steps:

1. Install Claude Code and/or Codex, or use the review sample fixture path if Apple cannot install the third-party CLI.
2. Open aI'm Thinking.
3. Choose the relevant session folder under Agent Folder Access.
4. Run the agent normally.
5. Observe state changes and typing audio.
6. Revoke access to verify the app stops monitoring the folder.

Before actual review, provide a deterministic review path if the reviewer cannot authenticate to Claude Code/Codex. A sanitized local fixture/demo mode is preferable to asking reviewers for third-party paid accounts.

## Review risk register

### Medium: third-party tool dependency

The core feature is easiest to demonstrate with Claude Code or Codex installed. Provide clear Review Notes and a deterministic local demonstration path before submission.

### Medium: external session file formats

Claude/Codex JSONL formats are not App Store APIs. Parsers already tolerate unknown fields/events and must continue to fail closed to silence rather than crash.

### Medium: sandbox bookmark transfer to helper

CI can validate entitlements and compilation, but only an actual sandboxed Mac run can prove that selected-folder access survives the Swift -> Rust helper transfer and recursive FSEvents/tailing.

### Low: Start at Login

Startup is user-controlled through the visible toggle. Never auto-enable it. This matches the requirement that login launch must have user consent.

### Low: background child process

The Rust Core is owned by the app through stdin/stdout and exits when the app shuts down. It is not a persistent daemon.

## Submission checklist

- [ ] App Store Connect app record created
- [ ] final bundle identifier registered
- [ ] sandboxed app launches under Xcode
- [ ] Claude folder can be selected and resumed after relaunch
- [ ] Codex folder can be selected and resumed after relaunch
- [ ] stale bookmark behavior tested
- [ ] revoke behavior tested
- [ ] helper cannot read unselected neighboring folders
- [ ] helper exits when app quits
- [ ] Start at Login defaults to off
- [ ] no Full Disk Access request
- [ ] no Accessibility request
- [ ] no shell or Agent settings changes
- [ ] PrivacyInfo.xcprivacy present in Archive
- [ ] Xcode privacy report reviewed
- [ ] App Store Connect privacy answers match binary behavior
- [ ] Archive validation succeeds
- [ ] TestFlight/internal distribution succeeds
- [ ] Review Notes include folder-selection steps
- [ ] deterministic reviewer demo path exists

## Non-goals

The App Store path must not add:

- network telemetry solely for activity detection
- a cloud transcript service
- a privileged helper
- a persistent daemon
- automatic Agent configuration modification
- Full Disk Access as a workaround for sandbox design
