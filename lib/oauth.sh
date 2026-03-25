#!/usr/bin/env bash
# OAuth login, token refresh, and token storage

OAUTH_SCOPES="sales_invoices documents estimates bank time_entries settings"

oauth_login_token() {
  local token="$1"

  if [[ -z "$token" ]]; then
    read -rp "Paste your API token: " token
  fi

  if [[ -z "$token" ]]; then
    echo "Error: No token provided." >&2
    return 1
  fi

  echo "Testing connection..."

  local host
  host=$(config_get_host)
  local api_prefix
  api_prefix=$(spec_api_prefix)
  local response_file
  response_file=$(mktemp)
  local http_code
  http_code=$(request_curl "$token" -s -o "$response_file" -w "%{http_code}" "${host}${api_prefix}/administrations.json")

  if [[ ! "$http_code" =~ ^2 ]]; then
    rm -f "$response_file"
    echo "Error: Token verification returned HTTP $http_code." >&2
    return 1
  fi

  local admin_id admin_name
  admin_id=$(jq -r '.[0].id' "$response_file")
  admin_name=$(jq -r '.[0].name' "$response_file")
  rm -f "$response_file"

  if [[ -z "$admin_id" || "$admin_id" == "null" ]]; then
    echo "Error: No administration found for this token." >&2
    return 1
  fi

  local token_data
  token_data=$(jq -n --arg t "$token" '{access_token: $t, token_type: "bearer", expires_at: 0}')
  sessions_store "$admin_id" "$admin_name" "$token_data"

  echo "Logged in to: $admin_name ($admin_id)"
  spec_update &>/dev/null &
}

oauth_login() {
  local host
  host=$(config_get_host)

  local client_id client_secret
  client_id=$(config_get client_id)
  client_secret=$(config_get client_secret)

  if [[ -z "$client_id" ]]; then
    read -rp "Client ID: " client_id
    config_set client_id "$client_id"
  fi
  if [[ -z "$client_secret" ]]; then
    read -rp "Client Secret: " client_secret
    config_set client_secret "$client_secret"
  fi

  local scope="${OAUTH_SCOPES// /+}"
  local auth_url="${host}/oauth/authorize?client_id=${client_id}&redirect_uri=urn:ietf:wg:oauth:2.0:oob&response_type=code&scope=${scope}"

  echo "Opening browser for authorization..."
  echo "If it doesn't open, visit: $auth_url"

  if command -v open &>/dev/null; then
    open "$auth_url"
  elif command -v xdg-open &>/dev/null; then
    xdg-open "$auth_url"
  fi

  read -rp "Paste the authorization code: " auth_code

  # Use temp file for curl body to avoid credentials in ps
  local body_file
  body_file=$(mktemp)
  chmod 600 "$body_file"
  cat > "$body_file" <<BODY
client_id=${client_id}&client_secret=${client_secret}&code=${auth_code}&redirect_uri=urn:ietf:wg:oauth:2.0:oob&grant_type=authorization_code
BODY

  local response
  response=$(curl -s -X POST "${host}/oauth/token" \
    -H "Content-Type: application/x-www-form-urlencoded" \
    -H "User-Agent: moneybird-cli/$VERSION" \
    -d @"$body_file")
  rm -f "$body_file"

  if ! echo "$response" | jq -e '.access_token' &>/dev/null; then
    echo "Login failed:" >&2
    echo "$response" | jq -r '.error_description // .error // "Unknown error"' >&2
    return 1
  fi

  # Fetch administration for this token
  local token
  token=$(echo "$response" | jq -r '.access_token')
  local api_prefix
  api_prefix=$(spec_api_prefix)
  local admin_response
  admin_response=$(mktemp)
  request_curl "$token" -s -o "$admin_response" "${host}${api_prefix}/administrations.json"

  local admin_id admin_name
  admin_id=$(jq -r '.[0].id' "$admin_response")
  admin_name=$(jq -r '.[0].name' "$admin_response")
  rm -f "$admin_response"

  if [[ -z "$admin_id" || "$admin_id" == "null" ]]; then
    echo "Error: No administration found for this token." >&2
    return 1
  fi

  local expires_in expires_at
  expires_in=$(echo "$response" | jq -r '.expires_in // 7200')
  expires_at=$(($(date +%s) + expires_in))

  local token_data
  token_data=$(echo "$response" | jq --argjson ea "$expires_at" '{access_token, refresh_token, token_type, expires_at: $ea}')
  sessions_store "$admin_id" "$admin_name" "$token_data"

  echo "Logged in to: $admin_name ($admin_id)"
  spec_update &>/dev/null &
}

oauth_logout() {
  local target="$1"

  if [[ "$target" == "--all" ]]; then
    sessions_remove_all
    echo "Logged out of all administrations."
    return 0
  fi

  if [[ -n "$target" ]]; then
    local sessions_file
    sessions_file=$(config_sessions_file)
    if [[ -f "$sessions_file" ]]; then
      local name
      name=$(jq -r --arg id "$target" '.sessions[$id].administration_name // empty' "$sessions_file")
      if [[ -z "$name" ]]; then
        echo "Error: No session for administration $target" >&2
        return 1
      fi
      sessions_remove "$target"
      echo "Logged out of: $name ($target)"
    else
      echo "Not logged in."
    fi
    return 0
  fi

  # No target specified: if one session, remove it; if multiple, ask
  local sessions_file
  sessions_file=$(config_sessions_file)
  if [[ ! -f "$sessions_file" ]]; then
    echo "Not logged in."
    return 0
  fi

  local count
  count=$(jq '.sessions | length' "$sessions_file")

  if [[ "$count" == "0" ]]; then
    echo "Not logged in."
    return 0
  fi

  if [[ "$count" == "1" ]]; then
    local name id
    id=$(jq -r '.sessions | keys[0]' "$sessions_file")
    name=$(jq -r '.sessions[.sessions | keys[0]].administration_name' "$sessions_file")
    sessions_remove_all
    echo "Logged out of: $name ($id)"
    return 0
  fi

  echo "Multiple sessions active:"
  sessions_list
  echo ""
  echo "Specify which to log out of:"
  echo "  moneybird-cli logout <id>"
  echo "  moneybird-cli logout --all"
}

oauth_get_token() {
  local token
  token=$(sessions_get_token)

  if [[ -z "$token" ]]; then
    echo "Error: Not logged in. Run: moneybird-cli login" >&2
    return 1
  fi

  local expires_at
  expires_at=$(sessions_get_expires_at)

  # expires_at == 0 means non-expiring token (personal token)
  if (( expires_at > 0 )); then
    local now
    now=$(date +%s)
    if (( now >= expires_at - 60 )); then
      oauth_refresh || return 1
      token=$(sessions_get_token)
    fi
  fi

  echo "$token"
}

oauth_refresh() {
  local host
  host=$(config_get_host)

  local sessions_file
  sessions_file=$(config_sessions_file)
  local admin_id
  admin_id=$(jq -r '.current // empty' "$sessions_file")

  local refresh_token
  refresh_token=$(jq -r --arg id "$admin_id" '.sessions[$id].refresh_token // empty' "$sessions_file")

  if [[ -z "$refresh_token" ]]; then
    echo "Error: No refresh token available." >&2
    echo "If using a personal token, create a new one in Moneybird." >&2
    echo "Otherwise, run: moneybird-cli login" >&2
    return 1
  fi

  local client_id client_secret
  client_id=$(config_get client_id)
  client_secret=$(config_get client_secret)

  [[ -n "$OPT_VERBOSE" ]] && echo "Refreshing access token..." >&2

  # Use temp file for curl body to avoid credentials in ps
  local body_file
  body_file=$(mktemp)
  chmod 600 "$body_file"
  cat > "$body_file" <<BODY
client_id=${client_id}&client_secret=${client_secret}&refresh_token=${refresh_token}&grant_type=refresh_token
BODY

  local response
  response=$(curl -s -X POST "${host}/oauth/token" \
    -H "Content-Type: application/x-www-form-urlencoded" \
    -H "User-Agent: moneybird-cli/$VERSION" \
    -d @"$body_file")
  rm -f "$body_file"

  if echo "$response" | jq -e '.access_token' &>/dev/null; then
    local expires_in expires_at
    expires_in=$(echo "$response" | jq -r '.expires_in // 7200')
    expires_at=$(($(date +%s) + expires_in))
    local token_data
    token_data=$(echo "$response" | jq --argjson ea "$expires_at" '{access_token, refresh_token, token_type, expires_at: $ea}')
    sessions_update_token "$token_data"
    spec_update &>/dev/null &
    return 0
  else
    echo "Error: Token refresh failed. Run: moneybird-cli login" >&2
    return 1
  fi
}
