---
title: Support
---

# aI'm Thinking Support

aI'm Thinking is a macOS menu bar app that plays keyboard sounds while Claude Code or Codex is thinking, writing, and editing.

## Requirements

- macOS 26.0 or later on Apple silicon
- Claude Code or Codex running on the same Mac

## Getting started (Mac App Store version)

1. Open aI'm Thinking. A welcome window appears.
2. Click **Choose Folder…** for each agent you use and select its session folder:
   - Claude Code: `~/.claude/projects`
   - Codex: `~/.codex/sessions`

   These folders are hidden. In the folder picker, press **Command-Shift-.** (period) to show hidden folders, or press **Command-Shift-G** and type the path.
3. Click **Done**. The app has no Dock icon; open it from the keycap icon in the menu bar.
4. Start `claude` or `codex` as usual. Sounds play while the agent works.

## No sound?

- Check that the menu does not show the volume at zero or muted.
- Check that the agent shows **Allowed** under **Agent Folder Access**. If you chose the wrong folder, click **Revoke** and choose it again.
- Only activity that starts after the app launches is played. Send a new prompt to the agent.
- If an agent shows **Unsupported format**, a Claude Code or Codex update changed its transcript format. Please report it.
- Try **Restart Monitor** in the menu.

## Contact

Report problems or ask questions on [GitHub Issues](https://github.com/den0206/aI-m-Thinking/issues). Attaching the output of **Copy Diagnostic Log** helps; it contains no transcript content or file paths.

[Privacy Policy](privacy.html)
