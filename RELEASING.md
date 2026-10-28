# Releasing Venice Balance

## How releases reach users

Omarchy installs a plugin by cloning the repository's default branch into
`~/.config/omarchy/plugins/<id>/`. `omarchy plugin update` fetches
`origin/HEAD` and fast-forwards that checkout. Tags and GitHub releases do not
control what users receive.

Consequences:

- `main` is the delivery channel. Anything merged to it can reach users.
- Keep the repository's default branch set to `main`; installed checkouts track
  it.
- Never force-push or rewrite `main`; an installed checkout can only
  fast-forward.
- Keep `main` releasable. Incomplete work stays on a branch, and validation and
  tests pass before anything lands.
- A tag marks a tested snapshot. It does not gate delivery.

## Versioning

Venice Balance follows [Semantic Versioning](https://semver.org/). Tags are
`vMAJOR.MINOR.PATCH`; `manifest.json`'s `version` is canonical and must equal
the tag without the `v`.

Before 1.0:

- `0.MINOR.0` adds features or makes breaking changes.
- `0.MINOR.PATCH` is a backwards-compatible fix.

Breaking changes include renaming or removing a setting, changing a setting's
default, changing where or how the token is stored, changing the helper's JSON
contract or exit codes, raising the minimum Omarchy version, and changing the
plugin id or entry points. Call them out with `**Breaking:**` in the changelog.

The balance helper's `User-Agent` embeds the full version. CI checks that it
matches `manifest.json`; bump both in the release commit.

Documentation, tests, refactors, and CI changes do not need a version bump or a
changelog entry unless they change user-visible behavior.

## Branching and cadence

- Work on a short-lived branch. Merge to `main` only when the change is
  complete, tested, and ready for users.
- Release each user-visible merge immediately: finalize the changelog, bump the
  version, and tag. Do not leave user-visible changes untagged on `main`.
- If several changes should ship together, combine them on a release branch,
  verify that branch, merge it to `main` once, and tag the merge.
- Documentation, test, and CI-only merges may sit after the last tag; they do
  not change what users run.

## Changelog

`CHANGELOG.md` follows
[Keep a Changelog 1.1.0](https://keepachangelog.com/en/1.1.0/).

- Add entries under `## [Unreleased]` in the same branch as the change.
- Use `Added`, `Changed`, `Deprecated`, `Removed`, `Fixed`, or `Security`.
- Write for users: what changed and what they need to do, not a commit log.
- Omit internal refactors, tests, and documentation unless users are affected.
- At release, move the entries under `## [X.Y.Z] - YYYY-MM-DD`, leave a new
  empty `Unreleased` section, and update the comparison links at the bottom.

## Release checklist

### 1. Prepare

Start from a clean, current tree. If you are on `main`, pull it first:

```bash
git switch main
git pull --ff-only
git status --porcelain   # must print nothing
```

Do the release work on the feature or release branch:

- Move the `Unreleased` entries to `## [X.Y.Z] - YYYY-MM-DD`.
- Set `version` in `manifest.json` to `X.Y.Z`.
- Set `User-Agent: omarchy-venice/X.Y.Z` in `bin/venice-billing`.

### 2. Verify

```bash
omarchy plugin validate .
node --test tests/model.test.js
./tests/helper.test.sh
./tests/app.test.sh
```

CI runs the tests, shell syntax checks, manifest checks, and version
consistency checks, including that a pushed tag has a matching `CHANGELOG.md`
section. A red run blocks the release. CI cannot run
`omarchy plugin validate`, so run it locally.

### 3. Smoke test

Install the working tree over the live plugin and restart the shell:

```bash
rsync -a --delete --exclude .git ./ \
  ~/.config/omarchy/plugins/net.fidelramos.venice/
omarchy restart shell
```

Check:

- The ring, tooltip, and panel agree with
  `omarchy-shell net.fidelramos.venice status`.
- Left click opens the panel, right click refreshes, middle click copies the
  summary.
- Saving a token works in the configured storage backend.
- Refresh works and the APP section reports the correct state.

### 4. Commit, tag, and push

```bash
git add CHANGELOG.md manifest.json bin/venice-billing
git commit -m "Release vX.Y.Z"
```

Confirm the commit is complete by validating a fresh clone, so no required file
was left untracked or uncommitted:

```bash
tmp=$(mktemp -d)
git clone --depth 1 . "$tmp/plugin"
omarchy plugin validate "$tmp/plugin"
rm -rf "$tmp"
```

If this fails, add the missing file and amend the release commit before tagging.
If the merge happened through a pull request, pull `main` after it before
tagging:

```bash
git switch main
git pull --ff-only
```

Then tag:

```bash
git tag -a vX.Y.Z -m "vX.Y.Z"
```

Confirm the tag and manifest agree before pushing:

```bash
test "$(git show vX.Y.Z:manifest.json | jq -r .version)" = "X.Y.Z"
```

Push `main` first, then the tag:

```bash
git push origin main
git push origin vX.Y.Z
```

Push `main` first. If it fails, do not push the tag, or the tag will point at a
commit that is not on the delivery branch. If `main` succeeds and the tag push
fails, create the tag on the same commit again and push it.

### 5. Publish the release

Create a GitHub release from the tag. Use the version's changelog section as the
notes:

```bash
awk -v v="X.Y.Z" '
  $0 ~ "^## \\[" v "\\]" { found = 1; next }
  found && /^## \[/ { exit }
  found && /^\[[^]]+\]:/ { exit }
  found { print }
' CHANGELOG.md > "/tmp/vX.Y.Z.md"

gh release create "vX.Y.Z" --verify-tag --title "vX.Y.Z" --notes-file "/tmp/vX.Y.Z.md"
```

### 6. Verify delivery

- Confirm a fresh clone reports the new version in `manifest.json`.
- If possible, run `omarchy plugin update net.fidelramos.venice --yes` on a
  machine with the previous version and check the new behavior.

### 7. Hotfixes

Branch from the latest release tag, fix the problem, add tests and a changelog
entry, bump the patch version, merge to `main`, and tag. If `main` has moved
past the tag, branch from `main` instead so the fix applies to what users run.
Never move an existing tag.

### 8. Bad releases

Revert the bad change on `main` with a normal commit, bump the patch version,
and tag a new release. Do not force-push. Delete a tag or GitHub release only
if it is clearly unconsumed and a new version replaces it.

## Optional branch protection

If the repository uses branch protection, require the `checks` workflow on
`main` and block force-pushes. This matches how installed checkouts update.
