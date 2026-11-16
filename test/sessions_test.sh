#!/usr/bin/env bash
# Tests for picking the session (token) that belongs to an administration
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PASS=0
FAIL=0

MONEYBIRD_CONFIG_DIR=$(mktemp -d)
export MONEYBIRD_CONFIG_DIR
trap 'rm -rf "$MONEYBIRD_CONFIG_DIR"' EXIT

source "$SCRIPT_DIR/lib/config.sh"

OPT_DEV=""
OPT_ADMINISTRATION=""
config_init

assert_equals() {
  local label="$1" expected="$2" actual="$3"
  if [[ "$expected" == "$actual" ]]; then
    echo "  PASS: $label"
    PASS=$((PASS + 1))
  else
    echo "  FAIL: $label"
    echo "    expected: $expected"
    echo "    got: $actual"
    FAIL=$((FAIL + 1))
  fi
}

# Two administrations with their own tokens; "222" is logged in last (current)
sessions_store "111" "Admin One" '{"access_token": "token-one", "token_type": "bearer", "expires_at": 0}'
sessions_store "222" "Admin Two" '{"access_token": "token-two", "token_type": "bearer", "expires_at": 100}'

echo "Session selection:"

OPT_ADMINISTRATION=""
assert_equals "no override uses the current session" "token-two" "$(sessions_get_token)"

OPT_ADMINISTRATION="111"
assert_equals "override uses that administration's token" "token-one" "$(sessions_get_token)"
assert_equals "override uses that administration's expiry" "0" "$(sessions_get_expires_at)"
assert_equals "override does not change the current administration" "222" "$(sessions_current_id)"

OPT_ADMINISTRATION="333"
assert_equals "override without a session falls back to the current token" "token-two" "$(sessions_get_token)"

echo ""
echo "Token refresh:"

OPT_ADMINISTRATION="111"
sessions_update_token '{"access_token": "token-one-refreshed", "expires_at": 200}'
sessions_file=$(config_sessions_file)
assert_equals "refresh updates the overridden session" "token-one-refreshed" \
  "$(jq -r '.sessions["111"].access_token' "$sessions_file")"
assert_equals "refresh leaves the current session alone" "token-two" \
  "$(jq -r '.sessions["222"].access_token' "$sessions_file")"

# --- Summary ---
echo ""
echo "Results: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]] && exit 0 || exit 1
