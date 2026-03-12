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

  local tokens_file
  tokens_file=$(config_tokens_file)

  # Store as non-expiring token (expires_at = 0 signals no expiry)
  jq -n --arg t "$token" '{access_token: $t, token_type: "bearer", expires_at: 0}' > "$tokens_file"
  chmod 600 "$tokens_file"

  echo "Token saved. Testing connection..."

  # Verify the token works
  local host
  host=$(config_get_host)
  local api_prefix
  api_prefix=$(spec_api_prefix)
  local http_code
  http_code=$(request_curl "$token" -s -o /dev/null -w "%{http_code}" "${host}${api_prefix}/administrations.json")

  if [[ "$http_code" =~ ^2 ]]; then
    echo "Login successful!"
    spec_update &>/dev/null &
  else
    echo "Warning: Token verification returned HTTP $http_code." >&2
    echo "The token has been saved but may not be valid." >&2
  fi
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
    -d @"$body_file")
  rm -f "$body_file"

  if echo "$response" | jq -e '.access_token' &>/dev/null; then
    oauth_store_tokens "$response"
    echo "Login successful!"
    spec_update &>/dev/null &
  else
    echo "Login failed:" >&2
    echo "$response" | jq -r '.error_description // .error // "Unknown error"' >&2
    return 1
  fi
}

oauth_logout() {
  local tokens_file
  tokens_file=$(config_tokens_file)

  if [[ ! -f "$tokens_file" ]]; then
    echo "Not logged in."
    return 0
  fi

  rm -f "$tokens_file"
  echo "Logged out."
}

oauth_store_tokens() {
  local response="$1"
  local tokens_file
  tokens_file=$(config_tokens_file)

  local expires_in
  expires_in=$(echo "$response" | jq -r '.expires_in // 7200')
  local expires_at
  expires_at=$(($(date +%s) + expires_in))

  echo "$response" | jq --argjson ea "$expires_at" '. + {expires_at: $ea}' > "$tokens_file"
  chmod 600 "$tokens_file"
}

oauth_get_token() {
  local tokens_file
  tokens_file=$(config_tokens_file)

  if [[ ! -f "$tokens_file" ]]; then
    echo "Error: Not logged in. Run: moneybird-cli login" >&2
    return 1
  fi

  local expires_at
  expires_at=$(jq -r '.expires_at // 0' "$tokens_file")

  # expires_at == 0 means non-expiring token (e.g. from --token login)
  if (( expires_at > 0 )); then
    local now
    now=$(date +%s)
    if (( now >= expires_at - 60 )); then
      oauth_refresh || return 1
    fi
  fi

  jq -r '.access_token' "$tokens_file"
}

oauth_refresh() {
  local tokens_file
  tokens_file=$(config_tokens_file)
  local host
  host=$(config_get_host)

  local refresh_token
  refresh_token=$(jq -r '.refresh_token // empty' "$tokens_file")

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
    -d @"$body_file")
  rm -f "$body_file"

  if echo "$response" | jq -e '.access_token' &>/dev/null; then
    oauth_store_tokens "$response"
    spec_update &>/dev/null &
    return 0
  else
    echo "Error: Token refresh failed. Run: moneybird-cli login" >&2
    return 1
  fi
}
