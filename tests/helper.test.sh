#!/bin/sh
# Exercises bin/venice-billing with stubbed curl and secret-tool. No network,
# no real keyring, no real token.

set -eu

here=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
helper="$here/../bin/venice-billing"
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT INT TERM

stub="$tmp/stub"
mkdir -p "$stub"

cat > "$stub/curl" <<'CURL'
#!/bin/sh
printf '%s\n' "$*" >> "${STUB_ARGV_FILE:-/dev/null}"
cat > "${STUB_STDIN_FILE:-/dev/null}"
out=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    -o) out="$2"; shift 2 ;;
    *) shift ;;
  esac
done
if [ -n "${STUB_CURL_ERR:-}" ]; then
  printf '%s\n' "$STUB_CURL_ERR" >&2
fi
if [ -n "$out" ]; then
  printf '%s' "${STUB_BODY:-}" > "$out"
fi
printf '%s' "${STUB_HTTP:-200}"
if [ -n "${STUB_CURL_RC:-}" ]; then
  exit "$STUB_CURL_RC"
fi
exit 0
CURL

cat > "$stub/secret-tool" <<'SECRET'
#!/bin/sh
if [ -n "${STUB_KEYRING_SLEEP:-}" ]; then
  sleep "$STUB_KEYRING_SLEEP"
fi
case "${1:-}" in
  lookup)
    if [ -n "${STUB_KEYRING_ERR:-}" ]; then
      printf '%s\n' "$STUB_KEYRING_ERR" >&2
      exit 1
    fi
    printf '%s' "${STUB_TOKEN:-}"
    ;;
  store)
    if [ -n "${STUB_KEYRING_STORE_ERR:-}" ]; then
      printf '%s\n' "$STUB_KEYRING_STORE_ERR" >&2
      exit 1
    fi
    cat > "${STUB_KEYRING_FILE:-/dev/null}"
    ;;
  clear)
    if [ -n "${STUB_KEYRING_FILE:-}" ]; then
      : > "$STUB_KEYRING_FILE"
    fi
    ;;
esac
SECRET

chmod +x "$stub/curl" "$stub/secret-tool"

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

run() {
  env PATH="$stub:$PATH" \
      VENICE_STATE_DIR="$tmp/state" \
      VENICE_API_URL="http://venice.test/api/v1/billing/balance" \
      "$helper" "$@"
}

export STUB_STDIN_FILE="$tmp/curl-stdin.txt"
export STUB_ARGV_FILE="$tmp/curl-argv.txt"
export STUB_KEYRING_FILE="$tmp/keyring.txt"

TOKEN="vapi-file-token-123"
BALANCE='{"canConsume":true,"consumptionCurrency":"DIEM","balances":{"diem":90.5,"usd":25,"bundledCredits":10,"earnedCredits":5},"diemEpochAllocation":100}'

# ---------------------------------------------------------------- file mode

if ! printf '%s\n' "$TOKEN" | run store-token --storage=file >/dev/null; then
  fail "store-token --storage=file failed"
fi
check_equal "$(stat -c '%a' "$tmp/state/token")" "600"

export STUB_BODY="$BALANCE"
export STUB_HTTP=200
capture run balance --storage=file
check_equal "$CAPTURE_RC" "0"
check_json "$CAPTURE_OUT" '.ok == true and .storage == "file" and .data.balances.diem == 90.5 and .data.diemEpochAllocation == 100'

grep -q "Authorization: Bearer $TOKEN" "$tmp/curl-stdin.txt" \
  || fail "token was not sent to curl over stdin"
grep -q -- "--config -" "$tmp/curl-argv.txt" \
  || fail "curl was not told to read the headers from stdin (--config -)"
if grep -q "$TOKEN" "$tmp/curl-argv.txt"; then
  fail "token leaked into curl argv"
fi

# No token configured is a distinct state, not an error.
rm -f "$tmp/state/token"
capture run balance --storage=file
check_equal "$CAPTURE_RC" "10"
check_json "$CAPTURE_OUT" '.ok == false and .kind == "no-token"'

# ------------------------------------------------------------ API failures

printf '%s\n' "$TOKEN" | run store-token --storage=file >/dev/null

export STUB_HTTP=401
export STUB_BODY='{"error":"bad token"}'
capture run balance --storage=file
check_equal "$CAPTURE_RC" "11"
check_json "$CAPTURE_OUT" '.ok == false and .kind == "auth" and .message == "bad token"'

# Venice's live endpoint uses 402 for an invalid Bearer key.
export STUB_HTTP=402
export STUB_BODY='{"error":"Authentication required"}'
capture run balance --storage=file
check_equal "$CAPTURE_RC" "11"
check_json "$CAPTURE_OUT" '.kind == "auth" and .message == "Authentication required"'

export STUB_HTTP=500
export STUB_BODY='{"error":"boom"}'
capture run balance --storage=file
check_equal "$CAPTURE_RC" "13"
check_json "$CAPTURE_OUT" '.kind == "http" and .message == "boom"'

export STUB_HTTP=000
export STUB_BODY=""
export STUB_CURL_RC=7
export STUB_CURL_ERR="Connection refused"
capture run balance --storage=file
check_equal "$CAPTURE_RC" "12"
check_json "$CAPTURE_OUT" '.kind == "network" and (.message | test("connect to Venice"))'

export STUB_CURL_RC=28
capture run balance --storage=file
check_equal "$CAPTURE_RC" "12"
check_json "$CAPTURE_OUT" '.kind == "network" and (.message | test("did not respond"))'
unset STUB_CURL_RC STUB_CURL_ERR

# A 200 response with garbage is a parse failure, not a zero balance.
export STUB_HTTP=200
export STUB_BODY='<html>not json</html>'
capture run balance --storage=file
check_equal "$CAPTURE_RC" "15"
check_json "$CAPTURE_OUT" '.kind == "parse"'

# --------------------------------------------------------------- keyring mode

export STUB_HTTP=200
export STUB_BODY="$BALANCE"
export STUB_TOKEN="vapi-keyring-token-456"

capture run balance --storage=keyring
check_equal "$CAPTURE_RC" "0"
check_json "$CAPTURE_OUT" '.ok == true and .storage == "keyring"'
grep -q "Authorization: Bearer vapi-keyring-token-456" "$tmp/curl-stdin.txt" \
  || fail "keyring token was not sent to curl"
if grep -q "vapi-keyring-token-456" "$tmp/curl-argv.txt"; then
  fail "keyring token leaked into curl argv"
fi

# Storing to the keyring succeeds and removes a stale file copy.
if ! printf '%s\n' "vapi-keyring-token-456" | run store-token --storage=keyring >/dev/null; then
  fail "store-token --storage=keyring failed"
fi
grep -q "vapi-keyring-token-456" "$tmp/keyring.txt" || fail "token was not stored in the keyring"
[ ! -f "$tmp/state/token" ] || fail "keyring store left a stale plaintext copy"

# A keyring store failure must not silently fall back to a file.
rm -f "$tmp/state/token"
export STUB_KEYRING_STORE_ERR="Failed to unlock the keyring"
if printf '%s\n' "vapi-another-token" | run store-token --storage=keyring >"$tmp/store-out.json"; then
  fail "keyring store should have failed"
else
  rc=$?
fi
check_equal "$rc" "14"
check_json "$(cat "$tmp/store-out.json")" '.kind == "keyring"'
[ ! -f "$tmp/state/token" ] || fail "failed keyring store wrote a plaintext file"
unset STUB_KEYRING_STORE_ERR

# The same rule for reads: a locked keyring is an error, not "no token".
export STUB_KEYRING_ERR="The keyring is locked"
capture run balance --storage=keyring
check_equal "$CAPTURE_RC" "14"
check_json "$CAPTURE_OUT" '.kind == "keyring" and (.message | test("locked"))'
unset STUB_KEYRING_ERR

# And a keyring that never answers is bounded rather than hanging a poll.
export STUB_KEYRING_SLEEP=5
export VENICE_KEYRING_TIMEOUT=1
capture run balance --storage=keyring
check_equal "$CAPTURE_RC" "14"
check_json "$CAPTURE_OUT" '.kind == "keyring" and (.message | test("did not respond"))'
unset STUB_KEYRING_SLEEP VENICE_KEYRING_TIMEOUT

# -------------------------------------------------------------- other errors

capture run balance --storage=nowhere
check_equal "$CAPTURE_RC" "15"
check_json "$CAPTURE_OUT" '.kind == "parse"'

rm -f "$tmp/state/token"
if printf '%s\n' 'not a "valid" token' | run store-token --storage=file >/dev/null 2>&1; then
  fail "an invalid token was accepted"
fi
[ ! -f "$tmp/state/token" ] || fail "an invalid token was written to disk"

# clear-token removes the file copy.
printf '%s\n' "$TOKEN" | run store-token --storage=file >/dev/null
run clear-token >/dev/null
[ ! -f "$tmp/state/token" ] || fail "clear-token left the file behind"

if [ "$failures" -ne 0 ]; then
  printf '%s helper test(s) failed\n' "$failures" >&2
  exit 1
fi
printf 'helper tests passed\n'
