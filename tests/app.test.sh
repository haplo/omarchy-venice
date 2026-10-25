#!/bin/sh
# Exercises bin/venice-app with a stubbed omarchy-webapp-install. No network,
# no real app launcher, no real home directory.

set -eu

here=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
helper="$here/../bin/venice-app"
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT INT TERM

home="$tmp/home"
state="$tmp/state"
stub="$tmp/stub"

export HOME="$home"
export VENICE_STATE_DIR="$state"
export PATH="$stub:$PATH"
export STUB_LOG="$tmp/install.log"

mkdir -p "$home/.local/share/applications" \
         "$home/.local/share/icons/hicolor/256x256/apps" \
         "$state" "$stub"

cat > "$stub/omarchy-webapp-install" <<'INSTALL'
#!/bin/sh
printf '%s|%s|%s\n' "$1" "$2" "$3" >> "${STUB_LOG:-/dev/null}"
if [ -n "${STUB_FAIL:-}" ]; then
  printf '%s\n' "$STUB_FAIL" >&2
  exit 1
fi
dir="$HOME/.local/share/applications"
mkdir -p "$dir"
cat > "$dir/$1.desktop" <<EOF
[Desktop Entry]
Version=1.0
Name=$1
Comment=$1
Exec=omarchy-launch-webapp "$2"
Terminal=false
Type=Application
Icon=$3
StartupNotify=true
EOF
chmod +x "$dir/$1.desktop"
INSTALL

cat > "$stub/update-desktop-database" <<'EOF'
#!/bin/sh
exit 0
EOF

chmod +x "$stub/omarchy-webapp-install" "$stub/update-desktop-database"

failures=0
fail() { printf 'FAIL: %s\n' "$*" >&2; failures=$((failures + 1)); }
check_equal() { [ "$1" = "$2" ] || fail "expected [$2], got [$1]"; }
check_json() { printf '%s' "$1" | jq -e "$2" >/dev/null 2>&1 || fail "json check failed: $2 (got: $1)"; }

CAPTURE_OUT=""
CAPTURE_RC=0
capture() {
  CAPTURE_RC=0
  CAPTURE_OUT=$("$@") || CAPTURE_RC=$?
}

desktop="$home/.local/share/applications/Venice.ai.desktop"
icon="$home/.local/share/icons/hicolor/256x256/apps/venice-ai.png"
marker="$state/app-install-done"
backup="$state/app-launcher-before-chat.desktop"

reset_all() {
  # Deliberately leave the state directory absent: creating the pre-update
  # backup before the directory exists was a real bug.
  rm -rf "$home/.local/share/applications" "$home/.local/share/icons" "$state"
  mkdir -p "$home/.local/share/applications" \
           "$home/.local/share/icons/hicolor/256x256/apps"
  rm -f "$tmp/install.log"
  unset STUB_FAIL
}

# ------------------------------------------------------------- nothing yet

reset_all
capture "$helper" status
check_equal "$CAPTURE_RC" "0"
check_json "$CAPTURE_OUT" '.ok == true and .installed == false and .managed == false and .chatUrl == false and .foreign == false'

capture "$helper" ensure
check_equal "$CAPTURE_RC" "0"
check_json "$CAPTURE_OUT" '.ok == true and .action == "installed"'
[ -f "$desktop" ] || fail "ensure did not create the launcher"
grep -q 'https://venice.ai/chat' "$desktop" || fail "launcher does not point at Chat"
[ -f "$marker" ] || fail "ensure did not write the one-shot marker"
check_equal "$(tail -1 "$tmp/install.log")" "Venice.ai|https://venice.ai/chat|"

# ------------------------------------------------- update an existing launcher

reset_all
printf 'icon' > "$icon"
cat > "$desktop" <<'EOF'
[Desktop Entry]
Version=1.0
Name=Venice.ai
Comment=Venice.ai
Exec=omarchy-launch-webapp "https://venice.ai/"
Terminal=false
Type=Application
Icon=venice-ai
StartupNotify=true
EOF

capture "$helper" status
check_json "$CAPTURE_OUT" '.installed == true and .managed == true and .chatUrl == false and .foreign == false and .url == "https://venice.ai/"'

capture "$helper" ensure
check_json "$CAPTURE_OUT" '.action == "updated"'
grep -q 'https://venice.ai/chat' "$desktop" || fail "existing launcher was not updated to Chat"
[ -f "$backup" ] || fail "the old launcher was not backed up"
[ -f "$marker" ] || fail "update did not write the one-shot marker"
check_equal "$(tail -1 "$tmp/install.log")" "Venice.ai|https://venice.ai/chat|venice-ai"

# ------------------------------------------------------- already on Chat

reset_all
cat > "$desktop" <<'EOF'
[Desktop Entry]
Name=Venice.ai
Exec=omarchy-launch-webapp "https://venice.ai/chat"
Type=Application
Icon=venice-ai
EOF

capture "$helper" ensure
check_json "$CAPTURE_OUT" '.action == "skipped"'
[ -f "$marker" ] || fail "already-installed ensure did not write the marker"
[ ! -s "$tmp/install.log" ] || fail "ensure called the installer for an up-to-date launcher"

# ---------------------------------------------- marker wins over a removal

reset_all
mkdir -p "$state"
: > "$marker"
capture "$helper" ensure
check_json "$CAPTURE_OUT" '.action == "skipped"'
[ ! -f "$desktop" ] || fail "ensure reinstalled after the one-shot marker"
[ ! -s "$tmp/install.log" ] || fail "ensure called the installer after the marker"

# ------------------------------------------------------- foreign launcher

reset_all
cat > "$desktop" <<'EOF'
[Desktop Entry]
Name=Venice.ai
Exec=/usr/bin/venice-native --open
Type=Application
EOF

capture "$helper" status
check_json "$CAPTURE_OUT" '.installed == true and .managed == false and .foreign == true'

capture "$helper" ensure
check_json "$CAPTURE_OUT" '.action == "skipped" and (.message | test("Another"))'
grep -q 'venice-native' "$desktop" || fail "foreign launcher was overwritten"
[ -f "$marker" ] || fail "foreign ensure did not write the checked marker"

rm -f "$marker"
capture "$helper" install
check_equal "$CAPTURE_RC" "14"
check_json "$CAPTURE_OUT" '.ok == false and .kind == "foreign"'
grep -q 'venice-native' "$desktop" || fail "manual install overwrote a foreign launcher"

# ---------------------------------------------------------- install failure

reset_all
export STUB_FAIL="Error: Failed to download icon."
capture "$helper" ensure
check_equal "$CAPTURE_RC" "14"
check_json "$CAPTURE_OUT" '.ok == false and .kind == "install" and (.message | test("Failed to download"))'
[ ! -f "$marker" ] || fail "a failed install wrote the marker"
[ ! -f "$desktop" ] || fail "a failed install created a launcher"
unset STUB_FAIL

# ------------------------------------------------ manual install ignores marker

reset_all
mkdir -p "$state"
: > "$marker"
capture "$helper" install
check_equal "$CAPTURE_RC" "0"
check_json "$CAPTURE_OUT" '.ok == true and .action == "installed"'
[ -f "$desktop" ] || fail "manual install did not create the launcher"
[ -s "$tmp/install.log" ] || fail "manual install did not call the installer"

# ------------------------------------------------------------- status on Chat

reset_all
cat > "$desktop" <<'EOF'
[Desktop Entry]
Name=Venice.ai
Exec=omarchy-launch-webapp "https://venice.ai/chat"
Type=Application
Icon=venice-ai
EOF
capture "$helper" status
check_json "$CAPTURE_OUT" '.installed == true and .managed == true and .chatUrl == true and .foreign == false and .url == "https://venice.ai/chat"'

if [ "$failures" -ne 0 ]; then
  printf '%s app test(s) failed\n' "$failures" >&2
  exit 1
fi
printf 'app tests passed\n'
