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

# --- Wrapper key detection ---
echo ""
echo "Wrapper key detection:"

echo "  -- Wrapped endpoint (POST contacts) --"
ROUTE_SPEC_PATH="/{administration_id}/contacts{format}"
ROUTE_METHOD="POST"
wrapper=$(request_find_wrapper_key)
assert_equals "uses 'contact' wrapper" "contact" "$wrapper"

echo ""
echo "  -- Flat endpoint (PATCH link_booking) --"
ROUTE_SPEC_PATH="/{administration_id}/financial_mutations/{id}/link_booking{format}"
ROUTE_METHOD="PATCH"
wrapper=$(request_find_wrapper_key)
assert_equals "no wrapper for flat schema" "" "$wrapper"

echo ""
echo "  -- Body building respects flat schema --"
ROUTE_SPEC_PATH="/{administration_id}/financial_mutations/{id}/link_booking{format}"
ROUTE_METHOD="PATCH"
request_build_params "PATCH" "http://example.test" \
  "--booking_type" "LedgerAccount" \
  "--booking_id" "123" \
  "--price" "10.00"
outer_keys=$(echo "$REQUEST_BODY" | jq -r 'keys | join(",")')
assert_equals "top-level keys are flat" "booking_id,booking_type,price" "$outer_keys"

echo ""
echo "  -- Body building wraps when schema wraps --"
ROUTE_SPEC_PATH="/{administration_id}/contacts{format}"
ROUTE_METHOD="POST"
request_build_params "POST" "http://example.test" \
  "--firstname" "Alice"
wrapped_firstname=$(echo "$REQUEST_BODY" | jq -r '.contact.firstname')
assert_equals "wraps under 'contact'" "Alice" "$wrapped_firstname"

# --- Flat-endpoint param validation ---
echo ""
echo "Flat-endpoint param validation:"

echo "  -- Known flat param produces no warning --"
ROUTE_SPEC_PATH="/{administration_id}/financial_mutations/{id}/link_booking{format}"
ROUTE_METHOD="PATCH"
VALIDATED_PARAMS=("--booking_type" "LedgerAccount" "--booking_id" "123")
stderr=$(request_warn_undeclared_params 2>&1)
assert_equals "no warning for declared flat params" "" "$stderr"

echo ""
echo "  -- Unknown flat param warns --"
VALIDATED_PARAMS=("--booking_type" "LedgerAccount" "--garbage" "x")
stderr=$(request_warn_undeclared_params 2>&1)
assert_contains "warns about unknown flat param" "$stderr" "--garbage is not a recognized parameter"
assert_not_contains "no warning for valid flat param" "$stderr" "--booking_type"

# --- Multipart/form-data endpoints ---
echo ""
echo "Multipart endpoints:"

echo "  -- JSON endpoint is not multipart --"
ROUTE_SPEC_PATH="/{administration_id}/contacts{format}"
ROUTE_METHOD="POST"
ct=$(request_spec_content_type)
assert_not_contains "content type for contacts POST is not multipart" "$ct" "multipart"

echo ""
echo "  -- Attachment endpoint reports multipart/form-data --"
ROUTE_SPEC_PATH="/{administration_id}/documents/receipts/{id}/attachments{format}"
ROUTE_METHOD="POST"
ct=$(request_spec_content_type)
assert_equals "content type for attachments POST" "multipart/form-data" "$ct"

echo ""
echo "  -- Binary fields on attachment endpoint --"
binary=$(request_spec_binary_fields | tr '\n' ',' | sed 's/,$//')
assert_equals "file is a binary field" "file" "$binary"

echo ""
echo "  -- No binary fields on JSON endpoint --"
ROUTE_SPEC_PATH="/{administration_id}/contacts{format}"
ROUTE_METHOD="POST"
binary=$(request_spec_binary_fields | tr '\n' ',' | sed 's/,$//')
assert_equals "no binary fields on contacts POST" "" "$binary"

echo ""
echo "  -- Form args upload binary fields with @path --"
ROUTE_SPEC_PATH="/{administration_id}/documents/receipts/{id}/attachments{format}"
ROUTE_METHOD="POST"
tmp_file=$(mktemp)
request_build_form_args "--file" "$tmp_file"
assert_equals "first form arg is -F" "-F" "${REQUEST_FORM_ARGS[0]}"
assert_equals "file field uses @path syntax" "file=@${tmp_file}" "${REQUEST_FORM_ARGS[1]}"
rm -f "$tmp_file"

echo ""
echo "  -- Missing file path errors out --"
stderr=$(request_build_form_args "--file" "/nonexistent/does-not-exist.png" 2>&1) || true
assert_contains "errors on missing file" "$stderr" "file not found"

# --- Summary ---
echo ""
echo "Results: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]] && exit 0 || exit 1
