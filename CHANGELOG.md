# Changelog

## 1.0.0

First public release of Byte Ports.

- Discover local development servers, AI agents and TCP listeners, read natively
  without running lsof.
- Servers, Agents and Actions tabs, with services of one project next to each
  other; Activity and Settings open from the header.
- One panel, opened from the menu bar icon, with ⌃⌥⌘R or by launching the app
  again: a floating window that remembers its position, or the notch panel
  instead. The app stays in the menu bar, without a Dock icon.
- Save launch commands as actions, edit them, follow their output live and
  restart them without a second copy. Commands run in zsh with your shell's
  environment variables.
- Pause, resume and stop your own processes with PID-reuse protection and
  confirmation, force stop services that don't respond, and quit agents: apps as
  with ⌘Q, command-line agents with SIGTERM.
- Quitting stops the services the app launched, with Force Quit for any that
  don't respond.
- Share local HTTP servers through Cloudflare Quick Tunnels after one local HTTP
  check, with a first-use public-access notice, the link copied as soon as it is
  ready, a globe in the menu bar and the notch, and stop controls in the row.
- Open a command-line agent's project folder in Terminal, iTerm2, Ghostty or Warp.
- Open at login, and check for updates manually or with an opt-in weekly check;
  a dot on the settings gear marks a newer version.
- Keyboard shortcuts, a three-step introduction, directional page transitions
  and an animated panel height, with support for VoiceOver, Full Keyboard
  Access, Reduce Motion and Reduce Transparency.
- English and German, following the macOS language.
- Settings migration from pre-release builds.

Requires macOS 26 or later and Apple Silicon.
