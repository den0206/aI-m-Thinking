---
title: Privacy Policy
---

# aI'm Thinking Privacy Policy

Last updated: October 3, 2026

aI'm Thinking is a macOS menu bar app that plays keyboard sounds while Claude Code or Codex is working. This policy explains what the app reads and stores.

## Summary

aI'm Thinking does not collect any data. It has no accounts, analytics, advertising, or crash reporting, and it makes no network connections. Everything happens on your Mac.

## What the app reads

To follow agent activity, the app reads the session transcript files that Claude Code and Codex write on your Mac:

- In the Mac App Store version, only the folders you choose in the standard macOS folder picker (for example `~/.claude/projects` or `~/.codex/sessions`).
- In the version downloaded from GitHub, the same default folders under your home directory.

Files are opened read-only. The app reads only records written after it starts and uses them to estimate whether the agent is thinking, writing, or using a tool. Prompts, responses, reasoning, source code, and tool output are never saved, copied, or sent anywhere, and the app never modifies Claude Code or Codex files or settings.

## What the app stores

On your Mac only, the app stores:

- Sound settings: sound pack, volume, typing speed, and mute.
- Whether the first-launch window has been completed.
- Folder access permissions for the folders you chose (security-scoped bookmarks, Mac App Store version only).

You can remove folder access at any time with **Revoke** under **Agent Folder Access** in the menu. Deleting the app removes its settings.

## Diagnostic log

**Copy Diagnostic Log** in the menu copies a short log of monitoring status (app and macOS versions, agent CLI versions, and activity states) to your clipboard. It contains no transcript content or file paths. It is copied only when you choose it, and it is shared only if you paste it somewhere yourself, for example in a support request.

## Children

The app does not collect personal information from anyone, including children.

## Changes

If this policy changes, the updated version will be posted on this page with a new date.

## Contact

Questions about privacy: [GitHub Issues](https://github.com/den0206/aI-m-Thinking/issues).
