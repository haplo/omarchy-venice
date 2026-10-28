# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).
Before 1.0, `0.MINOR.0` may add features or make breaking changes;
`0.MINOR.PATCH` is for backwards-compatible fixes.

## [Unreleased]

## [0.1.0] - 2026-10-28

Initial public release.

### Added

- A Venice Balance widget for the Omarchy bar, with a ring gauge for the current
  DIEM epoch (`diem / diemEpochAllocation`). The centre dot is filled when
  Venice will spend and hollow when it will not; when there is no DIEM
  allocation, a full ring means USD credit is available.
- A panel with the DIEM balance against the epoch allocation and a progress bar
  (including a countdown to the 00:00 UTC reset), the prepaid USD balance
  (negative USD shown as owed), bundled and earned credits, and the active
  consumption currency.
- Theme-aware colours: `accent` when healthy, `urgent` at or below the
  configurable low-balance threshold or when depleted. No hardcoded colours.
- An optional bar label (`none`, `auto`, `percent`, `usd`, `diem`, `both`),
  hidden automatically on a vertical bar, with the full balance in the tooltip.
- Token setup in the panel. The token is stored in the system keyring by
  default, or in a `0600` file under `~/.local/state/venice`; it is never shown
  again, never written to `shell.json`, and never passed in argv.
- A keyring-failure path that explains the problem, offers private-file
  storage, and backs off for five minutes instead of retrying every poll.
- Clear states for loading, a missing token, a rejected token, an unavailable
  keyring, an unreadable token file, offline with the last known balance, HTTP
  errors, and malformed responses, with a Retry action.
- After the first successful balance, an optional one-shot install of a
  `Venice.ai` web app launcher that opens `https://venice.ai/chat`, with an APP
  section for Install, Update to Chat and Open. A launcher the plugin did not
  create is left alone.
- Chat opens in the app window; API keys open in their own app window. Both
  dismiss the panel before handing off.
- Keyboard shortcuts: `r` refresh, `c` chat, `a` API keys, `Esc` close.
- Bar mouse actions: left opens the panel, right refreshes, middle copies the
  balance summary to the clipboard.
- One shared poller for every monitor, a configurable refresh interval
  (15–3600 seconds, default 30), and automatic pausing after a rejected token.
- Settings through the Omarchy bar: `refreshIntervalSec`, `barLabel`,
  `warnAtPercent`, `tokenStorage`, and `autoInstallApp`.
- IPC commands: `open`, `close`, `show`, `hide`, `toggle`, `refresh`, `chat`,
  `api`, and `status`.

### Security

- The API token is read only inside the helper and sent to `curl` on stdin, not
  in argv. It is validated against a restricted character set. File storage
  uses `0700`/`0600` permissions, and switching storage clears the other copy.
- No telemetry or analytics. Balance requests go only to `api.venice.ai`, with
  connect and total timeouts. The optional app install may fetch the site icon
  through `omarchy-webapp-install`.

[Unreleased]: https://github.com/haplo/omarchy-venice/compare/v0.1.0...HEAD
[0.1.0]: https://github.com/haplo/omarchy-venice/releases/tag/v0.1.0
