# AGENTS.md

Guidance for coding agents working on **Venice Balance**, a native Omarchy bar
plugin that shows a Venice.ai DIEM/USD balance and manages the API token.

User-facing documentation is `README.md`; release mechanics live in
`RELEASING.md`. Read both before changing behavior that users see.

## What this is

An Omarchy plugin (`net.fidelramos.venice`) with two entry points:

- a shared **service** (`Service.qml`) that polls the balance once for every
  monitor;
- a **bar widget** (`Panel.qml`) that renders the ring, popup, token setup, and
  app-launcher controls.

The plugin has no build step. QML is loaded directly by the shell, and the two
helpers in `bin/` are POSIX shell scripts run as `/bin/sh`.

## Layout

| Path | Role |
| --- | --- |
| `manifest.json` | Plugin metadata, settings defaults, and settings schema. |
| `Service.qml` | The poller: one timer, token lifecycle, last-good snapshot, app state. |
| `Panel.qml` | Bar button, popup, IPC handlers, keyboard and mouse behavior. |
| `VeniceRing.qml` | Canvas ring gauge. Theme colors only. |
| `Model.js` | Pure parsing, normalization, formatting, tiers, labels, tooltips. |
| `bin/venice-billing` | Token lookup, balance request, token store/clear. Prints JSON. |
| `bin/venice-app` | Status/install for the `Venice.ai` web app launcher. |
| `tests/model.test.js` | Node tests for `Model.js`. |
| `tests/helper.test.sh` | Shell tests for `bin/venice-billing`, with stubbed `curl`/`secret-tool`. |
| `tests/app.test.sh` | Shell tests for `bin/venice-app`, with stubbed Omarchy installer. |
| `.github/workflows/checks.yml` | CI: validation, shell syntax, version consistency, all tests. |

## Commands

Run these before calling any change finished:

```bash
omarchy plugin validate .
node --test tests/model.test.js
./tests/helper.test.sh
./tests/app.test.sh
```

`omarchy plugin validate` only runs locally; CI cannot run it. CI also runs
`sh -n` over both helpers and both shell tests, and checks that the manifest
version matches the `User-Agent` in `bin/venice-billing`.

To try a working tree in the live shell:

```bash
rsync -a --delete --exclude .git ./ \
  ~/.config/omarchy/plugins/net.fidelramos.venice/
omarchy restart shell
```

Saving files under the installed plugin directory triggers a plugin rescan,
but the shell keeps live bar-widget and service instances. QML or `Service.qml`
changes need `omarchy restart shell`.

## Hard invariants

### The API token

- The token is read **only** inside `bin/venice-billing`. QML touches it only
  in the password field and hands it to the helper on stdin.
- Never pass the token in argv, an environment variable visible to other
  processes, a log, a tooltip, or `shell.json`.
- `curl` receives the `Authorization` header through stdin via
  `curl --config -`. Do not switch to `-H` (argv is world-readable).
- Keep the token character allowlist and the `0700` state directory / `0600`
  token file permissions.
- Keyring is the default. File storage is an explicit fallback, never a silent
  downgrade. Storing in one backend must clear the other.
- An invalid key is `401`, `402` (the x402 challenge), or `403`; all three mean
  "replace the token" and map to the `auth` kind.

### Helper JSON contract

Every action in `bin/venice-billing` and `bin/venice-app` prints exactly one
JSON object on stdout and nothing else. Usage/help text goes to stderr and
exits `64`; actions always answer with JSON:

```json
{"ok":true,"storage":"keyring","data":{...}}
{"ok":false,"kind":"auth","message":"..."}
```

`venice-billing` exit codes: `0` ok, `10` no-token, `11` auth, `12` network,
`13` http, `14` keyring/file, `15` parse, `64` usage. Stable kind/exit-code
changes are breaking changes. Error messages should tell the user what to do
next, not expose tokens or raw headers.

Helpers require `jq` and POSIX `sh` only. Do not introduce bash features.
Failures are reported, not retried silently.

### App launcher

`bin/venice-app install` only creates a launcher when no `Venice.ai` desktop
file exists. Never edit, replace, or remove an existing launcher, even when the
user clicks Install: answer with `kind:"exists"` and let the panel explain.
There is no automatic install; only the APP section's button invokes the helper.

### Pure model logic

`Model.js` must stay free of QML types, singletons, and filesystem access so
Node can test it. Inject time (`now`) instead of calling `Date.now()` in new
logic that needs to be deterministic. Parsing failures must surface as errors,
never as a zero balance.

### QML and theming

- Use Omarchy theme tokens (`Commons.Color.*`, `Commons.Style.*`, `bar.accent`,
  `bar.urgent`, `bar.foreground`) and their spacing/font scales. No hardcoded
  green/amber/red or pixel sizes that bypass the theme.
- The bar widget is instantiated once per monitor. Keep all polling, token
  reads, and shared state in the service; do not add per-monitor requests.
- `barLabel` text is always hidden on a vertical bar; the tooltip carries the
  full balance.
- Preserve the honest states already modeled: loading, no token, rejected
  token, keyring unavailable, unreadable file, offline with last known
  balance, HTTP error, malformed response.

### Settings

`manifest.json` is the source of truth for keys, types, defaults, and ranges.
When adding or changing a setting, update all of:

1. `manifest.json` `barWidget.defaults` and `barWidget.schema`;
2. the corresponding read in `Service.qml` (`setting`, `intSetting`,
   `storageSetting`);
3. the settings table in `README.md`;
4. a changelog entry if users are affected.

Renaming or removing a setting, changing a default or range, changing token
storage, changing the helper JSON contract/exit codes, raising the minimum
Omarchy version, or changing the plugin id or entry points is a **breaking
change**.

## Repository workflow

- `main` is the delivery channel. Installed checkouts track it and can only
  fast-forward. Never force-push or rewrite `main`.
- Work on a short-lived branch and merge only complete, tested changes.
- Do not leave user-visible changes untagged on `main`; release each one.
- Never move an existing tag. Fix forward with a patch release.

### Versions

`manifest.json` `version` is canonical. It must equal the tag without `v`, the
`User-Agent: omarchy-venice/X.Y.Z` line in `bin/venice-billing`, and the
`## [X.Y.Z]` changelog section. Bump all together in the release commit.

### Changelog

Follow Keep a Changelog. Add user-visible entries under `## [Unreleased]` in
the same branch as the change, using `Added`, `Changed`, `Deprecated`,
`Removed`, `Fixed`, or `Security`. Write what changed for users, not a commit
log. Skip internal refactors, tests, and documentation unless users are
affected. At release, move entries to a dated version section and update the
comparison links.

## Change checklist

- **Model change** → add or update a test in `tests/model.test.js`.
- **Helper change** → add a stub-based test in `tests/helper.test.sh` or
  `tests/app.test.sh`; keep the JSON contract and exit codes documented.
- **UI state change** → wire it through `Service.qml`, render it in
  `Panel.qml`, and cover the corresponding label/tooltip in `Model.js` tests.
- **New setting** → update manifest, service, README, and changelog.
- **Security-sensitive change** → verify the token never reaches argv, the
  environment, or disk outside the approved backend; update README and
  `CHANGELOG.md` security notes.
- **User-visible change** → update README and `CHANGELOG.md`, then follow
  `RELEASING.md` (version bump, tag, GitHub release).

## Scope

The only network request is the balance lookup to `api.venice.ai` (plus the
optional favicon fetch during the user-requested app install). Do not add
telemetry, analytics, or third-party services. `bin/` is intentionally
re-included in `.gitignore`; keep both helper paths tracked.
