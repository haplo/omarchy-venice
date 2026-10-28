#!/bin/sh
# Exercises bin/venice-app with a stubbed omarchy-webapp-install. No network,
# no real app launcher, no real home directory.

set -eu

here=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
helper="$here/../bin/venice-app"
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT INT TERM

home="$tmp/home"
stub="$tmp/stub"

export HOME="$home"
export PATH="$stub:$PATH"
export STUB_LOG="$tmp/install.log"

mkdir -p "$home/.local/share/applications" \
         "$home/.local/share/icons/hicolor/256x256/apps" \
         "$stub"

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

reset_all() {
  rm -rf "$home/.local/share/applications" "$home/.local/share/icons"
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

capture "$helper" install
check_equal "$CAPTURE_RC" "0"
check_json "$CAPTURE_OUT" '.ok == true and .action == "installed"'
[ -f "$desktop" ] || fail "install did not create the launcher"
grep -q 'https://venice.ai/chat' "$desktop" || fail "launcher does not point at Chat"
check_equal "$(tail -1 "$tmp/install.log")" "Venice.ai|https://venice.ai/chat|"

# --------------------------------------------------------- icon reuse

reset_all
printf 'icon' > "$icon"
capture "$helper" install
check_equal "$CAPTURE_RC" "0"
check_equal "$(tail -1 "$tmp/install.log")" "Venice.ai|https://venice.ai/chat|venice-ai"

# -------------------------------------- existing managed launcher, landing page

reset_all
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

capture "$helper" install
check_equal "$CAPTURE_RC" "14"
check_json "$CAPTURE_OUT" '.ok == false and .kind == "exists"'
grep -q 'https://venice.ai/"' "$desktop" || fail "existing launcher was modified"
[ ! -s "$tmp/install.log" ] || fail "install called the installer for an existing launcher"

# ---------------------------------------------------- existing launcher on Chat

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

capture "$helper" install
check_equal "$CAPTURE_RC" "14"
check_json "$CAPTURE_OUT" '.ok == false and .kind == "exists"'
grep -q 'https://venice.ai/chat' "$desktop" || fail "existing Chat launcher was modified"
[ ! -s "$tmp/install.log" ] || fail "install called the installer for an existing launcher"

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

capture "$helper" install
check_equal "$CAPTURE_RC" "14"
check_json "$CAPTURE_OUT" '.ok == false and .kind == "exists"'
grep -q 'venice-native' "$desktop" || fail "foreign launcher was overwritten"
[ ! -s "$tmp/install.log" ] || fail "install called the installer for a foreign launcher"

# ---------------------------------------------------------- install failure

reset_all
export STUB_FAIL="Error: Failed to download icon."
capture "$helper" install
check_equal "$CAPTURE_RC" "14"
check_json "$CAPTURE_OUT" '.ok == false and .kind == "install" and (.message | test("Failed to download"))'
[ ! -f "$desktop" ] || fail "a failed install created a launcher"
unset STUB_FAIL

# --------------------------------------------------------- ensure is gone

reset_all
capture "$helper" ensure
check_equal "$CAPTURE_RC" "64"
check_json "$CAPTURE_OUT" '.ok == false and .kind == "parse"'
[ ! -f "$desktop" ] || fail "the removed ensure command still created a launcher"

if [ "$failures" -ne 0 ]; then
  printf '%s app test(s) failed\n' "$failures" >&2
  exit 1
fi
printf 'app tests passed\n'
