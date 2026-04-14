#!/usr/bin/env bash
# Tests for parameter validation
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PASS=0
FAIL=0

# Source the CLI with minimal setup
export MONEYBIRD_OUTPUT=raw
source "$SCRIPT_DIR/lib/config.sh"
source "$SCRIPT_DIR/lib/spec.sh"
source "$SCRIPT_DIR/lib/request.sh"

config_init

assert_contains() {
  local label="$1" haystack="$2" needle="$3"
  if [[ "$haystack" == *"$needle"* ]]; then
    echo "  PASS: $label"
    PASS=$((PASS + 1))
  else
    echo "  FAIL: $label"
    echo "    expected to contain: $needle"
    echo "    got: $haystack"
    FAIL=$((FAIL + 1))
  fi
}

assert_not_contains() {
  local label="$1" haystack="$2" needle="$3"
  if [[ "$haystack" != *"$needle"* ]]; then
    echo "  PASS: $label"
    PASS=$((PASS + 1))
  else
    echo "  FAIL: $label"
    echo "    expected NOT to contain: $needle"
    echo "    got: $haystack"
    FAIL=$((FAIL + 1))
  fi
}

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

# --- Undeclared param warning tests ---
echo "Undeclared parameter warnings:"

echo "  -- Unknown param on GET --"
ROUTE_SPEC_PATH="/{administration_id}/reports/general_ledger{format}"
ROUTE_METHOD="GET"

VALIDATED_PARAMS=("--bogus" "foo")
stderr=$(request_warn_undeclared_params 2>&1)
assert_contains "warns about unknown param" "$stderr" "--bogus is not a recognized parameter"

echo ""
echo "  -- Known param produces no warning --"
VALIDATED_PARAMS=("--period" "prev_year")
stderr=$(request_warn_undeclared_params 2>&1)
assert_equals "no warning for known param" "" "$stderr"

echo ""
echo "  -- Mix of known and unknown --"
VALIDATED_PARAMS=("--period" "prev_year" "--unknown" "bar")
stderr=$(request_warn_undeclared_params 2>&1)
assert_contains "warns about unknown" "$stderr" "--unknown is not a recognized parameter"
assert_not_contains "no warning for known" "$stderr" "--period"

echo ""
echo "  -- No spec path (skip validation) --"
ROUTE_SPEC_PATH=""
VALIDATED_PARAMS=("--anything" "goes")
stderr=$(request_warn_undeclared_params 2>&1)
assert_equals "no warning without spec path" "" "$stderr"

# --- Summary ---
echo ""
echo "Results: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]] && exit 0 || exit 1
