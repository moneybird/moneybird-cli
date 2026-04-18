#!/usr/bin/env bash
# OpenAPI spec fetching, caching, and querying

SPEC_FILE="$CONFIG_DIR/openapi.json"
SPEC_ETAG_FILE="$CONFIG_DIR/spec_etag"
SPEC_URL="https://raw.githubusercontent.com/moneybird/openapi/refs/heads/main/openapi.json"
SPEC_MAX_AGE=86400 # 24 hours

spec_ensure() {
  if [[ ! -f "$SPEC_FILE" ]]; then
    spec_update
    return $?
  fi

  local mod_time now age
  if [[ "$(uname)" == "Darwin" ]]; then
    mod_time=$(stat -f %m "$SPEC_FILE")
  else
    mod_time=$(stat -c %Y "$SPEC_FILE")
  fi
  now=$(date +%s)
  age=$((now - mod_time))

  if (( age > SPEC_MAX_AGE )); then
    [[ -n "$OPT_VERBOSE" ]] && echo "Spec is stale, updating in background..." >&2
    spec_update &>/dev/null &
  fi
}

spec_update() {
  local etag_args=()
  if [[ -f "$SPEC_ETAG_FILE" ]]; then
    etag_args=(-H "If-None-Match: $(cat "$SPEC_ETAG_FILE")")
  fi

  local tmp_file headers_file
  tmp_file=$(mktemp)
  headers_file=$(mktemp)

  local http_code
  http_code=$(curl -s -w "%{http_code}" -o "$tmp_file" -D "$headers_file" \
    ${etag_args[@]+"${etag_args[@]}"} \
    "$SPEC_URL")

  if [[ "$http_code" == "304" ]]; then
    [[ -n "$OPT_VERBOSE" ]] && echo "Spec is up to date." >&2
    touch "$SPEC_FILE"
    rm -f "$tmp_file" "$headers_file"
    return 0
  fi

  if [[ "$http_code" != "200" ]]; then
    echo "Error: Failed to fetch spec (HTTP $http_code)" >&2
    rm -f "$tmp_file" "$headers_file"
    return 1
  fi

  # Validate it's valid JSON
  if ! jq '.' "$tmp_file" > /dev/null 2>&1; then
    echo "Error: Fetched spec is not valid JSON" >&2
    rm -f "$tmp_file" "$headers_file"
    return 1
  fi

  # Extract and store ETag
  local new_etag
  new_etag=$(grep -i '^etag:' "$headers_file" | sed 's/^[^:]*: *//;s/\r$//')
  [[ -n "$new_etag" ]] && echo "$new_etag" > "$SPEC_ETAG_FILE"

  mv "$tmp_file" "$SPEC_FILE"
  rm -f "$headers_file"
  [[ -n "${OPT_VERBOSE:-}" ]] && echo "Spec updated." >&2 || true
}

# Derive the API base path from the spec's servers field
spec_api_prefix() {
  if [[ ! -f "$SPEC_FILE" ]]; then
    echo "/api/v2"
    return
  fi
  local prefix
  prefix=$(jq -r '.servers[0].url // "https://moneybird.com/api/v2"' "$SPEC_FILE")
  # Strip the host, keep only the path portion
  echo "$prefix" | sed -E 's|https?://[^/]+||'
}

spec_query() {
  # Pass all arguments through to jq (supports --arg, etc.)
  jq -r "$@" "$SPEC_FILE"
}

# List CRUD-able sub-types of a resource (e.g. documents → general_documents, receipts, ...).
# A sub-type is a literal path segment that has an /{id}{format} endpoint.
spec_resource_subtypes() {
  local resource="$1"
  spec_query --arg r "$resource" '
    .paths | keys[]
    | capture("^/\\{administration_id\\}/" + $r + "/(?<sub>[a-z_]+)/\\{id\\}\\{format\\}$")
    | .sub
  ' 2>/dev/null | sort -u
}

# True when the resource is a namespace with CRUD-able sub-types but no direct endpoints.
spec_is_namespace() {
  local resource="$1"
  [[ -n "$(spec_resource_subtypes "$resource")" ]]
}
