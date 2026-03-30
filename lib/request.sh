#!/usr/bin/env bash
# curl wrapper with auth, body building, and error handling

# Global temp file tracking for cleanup
REQUEST_TMP_FILES=()

request_cleanup() {
  rm -f ${REQUEST_TMP_FILES[@]+"${REQUEST_TMP_FILES[@]}"}
  REQUEST_TMP_FILES=()
}

request_tmpfile() {
  local f
  f=$(mktemp)
  REQUEST_TMP_FILES+=("$f")
  echo "$f"
}

# Execute a curl request with auth header passed via file (not visible in ps)
request_curl() {
  local token="$1"; shift

  local auth_file
  auth_file=$(request_tmpfile)
  chmod 600 "$auth_file"
  printf 'header = "Authorization: Bearer %s"\n' "$token" > "$auth_file"
  printf 'header = "User-Agent: moneybird-cli/%s"\n' "$VERSION" >> "$auth_file"

  curl -K "$auth_file" "$@"
}

request_execute() {
  local method="$1" url="$2"
  shift 2
  local params=()
  [[ $# -gt 0 ]] && params=("$@")

  # Build request body or query params
  local body="" query_params=""
  if [[ ${#params[@]} -gt 0 ]]; then
    request_build_params "$method" "$url" ${params[@]+"${params[@]}"}
    body="$REQUEST_BODY"
    query_params="$REQUEST_QUERY"
  fi

  [[ -n "$query_params" ]] && url="${url}?${query_params}"

  if [[ -n "$OPT_DRY_RUN" ]]; then
    echo "$method $url"
    [[ -n "$body" ]] && echo "$body" | jq '.'
    return 0
  fi

  local token
  token=$(oauth_get_token) || return 1

  [[ -n "$OPT_VERBOSE" ]] && echo ">>> $method $url" >&2

  trap 'request_cleanup' RETURN

  local headers_file response_file
  headers_file=$(request_tmpfile)
  response_file=$(request_tmpfile)

  local curl_args=(
    -s
    -X "$method"
    -H "Content-Type: application/json"
    -D "$headers_file"
    -o "$response_file"
    -w "%{http_code}"
  )

  [[ -n "$body" ]] && curl_args+=(-d "$body")

  local http_code
  http_code=$(request_curl "$token" "${curl_args[@]}" "$url")
  local response
  response=$(cat "$response_file")

  REQUEST_HEADERS_FILE="$headers_file"
  request_handle_response "$http_code" "$response" "$method" "$url" ${params[@]+"${params[@]}"}
}

# Extract Retry-After value from a curl-dumped headers file.
# Returns the number of seconds to wait, or empty if header is missing.
# The Moneybird API returns Retry-After as a Unix timestamp (epoch seconds).
request_parse_retry_after() {
  local headers_file="$1"
  local value
  value=$(grep -i '^retry-after:' "$headers_file" 2>/dev/null | head -1 | tr -d '\r' | awk '{print $2}')
  if [[ -n "$value" && "$value" =~ ^[0-9]+$ ]]; then
    local now
    now=$(date +%s)
    local delta=$(( value - now ))
    (( delta < 0 )) && delta=0
    echo "$delta"
  fi
}

request_build_params() {
  local method="$1" url="$2"
  shift 2
  local params=("$@")

  REQUEST_BODY=""
  REQUEST_QUERY=""

  if [[ "$method" == "GET" || "$method" == "DELETE" ]]; then
    local qp=""
    local i=0
    while (( i < ${#params[@]} )); do
      local key="${params[$i]}"
      local value="${params[$((i+1))]}"
      key="${key#--}"
      [[ -n "$qp" ]] && qp+="&"
      qp+="${key}=$(request_urlencode "$value")"
      i=$((i + 2))
    done
    REQUEST_QUERY="$qp"
    return
  fi

  # POST/PATCH/PUT — find wrapper key from spec and build JSON body
  local wrapper_key
  wrapper_key=$(request_find_wrapper_key)

  local body_obj="{}"
  local i=0
  while (( i < ${#params[@]} )); do
    local key="${params[$i]}"
    local value="${params[$((i+1))]}"
    key="${key#--}"

    # Try to parse value as JSON (arrays/objects/numbers/booleans), fallback to string
    # Only use --argjson for values that start with [, {, or are numeric/true/false/null
    if [[ -n "$value" && "$value" =~ ^[\[\{0-9tfn] ]] && echo "$value" | jq -e '.' &>/dev/null 2>&1; then
      body_obj=$(echo "$body_obj" | jq --arg k "$key" --argjson v "$value" '.[$k] = $v')
    else
      body_obj=$(echo "$body_obj" | jq --arg k "$key" --arg v "$value" '.[$k] = $v')
    fi
    i=$((i + 2))
  done

  if [[ -n "$wrapper_key" ]]; then
    REQUEST_BODY=$(jq -n --arg wk "$wrapper_key" --argjson obj "$body_obj" '{($wk): $obj}')
  else
    REQUEST_BODY="$body_obj"
  fi
}

request_find_wrapper_key() {
  [[ -z "${ROUTE_SPEC_PATH:-}" ]] && return 0

  local wrapper
  wrapper=$(spec_query --arg p "$ROUTE_SPEC_PATH" '
    (.paths[$p] // {}) | to_entries[]
    | select(.value.requestBody // null | . != null)
    | .value.requestBody.content | to_entries[0].value.schema.properties
    | keys[0] // empty
  ' 2>/dev/null | head -1)

  echo "$wrapper"
}

request_urlencode() {
  local string="$1"
  jq -rn --arg s "$string" '$s | @uri'
}

request_handle_response() {
  local http_code="$1" response="$2" method="$3" url="$4"
  shift 4
  local params=()
  [[ $# -gt 0 ]] && params=("$@")

  case "$http_code" in
    2[0-9][0-9])
      if [[ -n "$response" && "$response" != "null" ]]; then
        output_format "$response"
      elif [[ "$http_code" == "204" ]]; then
        [[ -n "$OPT_VERBOSE" ]] && echo "Success (no content)" >&2 || true
      fi
      ;;
    401)
      [[ -n "$OPT_VERBOSE" ]] && echo "Token expired, refreshing..." >&2
      if oauth_refresh; then
        request_execute "$method" "$url" ${params[@]+"${params[@]}"}
      else
        echo "Error: Authentication failed (401)" >&2
        return 1
      fi
      ;;
    404)
      echo "Error: Not found (404)" >&2
      request_show_error_body "$response"
      return 1
      ;;
    422)
      echo "Error: Validation failed (422)" >&2
      request_show_error_body "$response"
      return 1
      ;;
    429)
      local retry_after
      retry_after=$(request_parse_retry_after "${REQUEST_HEADERS_FILE:-}")
      if [[ -n "$retry_after" ]]; then
        echo "Error: Rate limited (429). Retry after ${retry_after}s." >&2
      else
        echo "Error: Rate limited (429)." >&2
      fi
      return 1
      ;;
    *)
      echo "Error: HTTP $http_code" >&2
      request_show_error_body "$response"
      return 1
      ;;
  esac
}

# Always show the full error response body for debugging
request_show_error_body() {
  local response="$1"
  if [[ -z "$response" ]]; then
    return
  fi
  if echo "$response" | jq '.' >&2 2>/dev/null; then
    :
  else
    echo "$response" >&2
  fi
}
