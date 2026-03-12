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

  request_cleanup

  request_handle_response "$http_code" "$response" "$method" "$url" ${params[@]+"${params[@]}"}
}

# Auto-paginate: fetch all pages and merge results
request_paginate() {
  local base_url="$1"
  shift
  local params=()
  [[ $# -gt 0 ]] && params=("$@")

  local token
  token=$(oauth_get_token) || return 1

  local all_results="[]"
  local page=1
  local per_page=100

  while true; do
    local url="${base_url}"
    local qp="page=${page}&per_page=${per_page}"

    if [[ ${#params[@]} -gt 0 ]]; then
      local i=0
      while (( i < ${#params[@]} )); do
        local key="${params[$i]}"
        local value="${params[$((i+1))]}"
        key="${key#--}"
        qp+="&${key}=$(request_urlencode "$value")"
        i=$((i + 2))
      done
    fi
    url="${url}?${qp}"

    [[ -n "$OPT_VERBOSE" ]] && echo ">>> GET $url (page $page)" >&2

    trap 'request_cleanup' RETURN

    local headers_file response_file
    headers_file=$(request_tmpfile)
    response_file=$(request_tmpfile)

    local http_code
    http_code=$(request_curl "$token" -s -X GET \
      -H "Content-Type: application/json" \
      -D "$headers_file" \
      -o "$response_file" \
      -w "%{http_code}" \
      "$url")

    local response
    response=$(cat "$response_file")
    request_cleanup

    if [[ ! "$http_code" =~ ^2 ]]; then
      request_handle_response "$http_code" "$response" "GET" "$url"
      return $?
    fi

    local count
    count=$(echo "$response" | jq 'if type == "array" then length else 0 end')
    all_results=$(echo "$all_results" "$response" | jq -s '.[0] + .[1]')

    [[ -n "$OPT_VERBOSE" ]] && echo ">>> Page $page: $count items" >&2

    if (( count < per_page )); then
      break
    fi
    page=$((page + 1))
  done

  output_format "$all_results"
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
  wrapper_key=$(request_find_wrapper_key "$url")

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
  local url="$1"

  # Convert actual URL to spec path pattern for lookup
  local api_prefix
  api_prefix=$(spec_api_prefix)
  local path
  path=$(echo "$url" | sed -E "
    s|https?://[^/]+${api_prefix}||
    s|/[0-9]+/|/{administration_id}/|
    s|/[0-9]+\\.json|/{id}.json|
    s|\\.json|{format}|
  ")

  local wrapper
  wrapper=$(spec_query --arg p "$path" '
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
        [[ -n "$OPT_VERBOSE" ]] && echo "Success (no content)" >&2
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
      echo "Error: Rate limited (429)" >&2
      echo "Try again later." >&2
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
