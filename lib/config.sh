#!/usr/bin/env bash
# Config management for moneybird-cli

CONFIG_DIR="${MONEYBIRD_CONFIG_DIR:-$HOME/.config/moneybird-cli}"
CONFIG_FILE="$CONFIG_DIR/config.json"

config_init() {
  if [[ ! -d "$CONFIG_DIR" ]]; then
    mkdir -p "$CONFIG_DIR"
    chmod 700 "$CONFIG_DIR"
  fi
  if [[ ! -f "$CONFIG_FILE" ]]; then
    echo '{}' > "$CONFIG_FILE"
    chmod 600 "$CONFIG_FILE"
  fi
}

config_get() {
  local key="$1"
  jq -r --arg k "$key" '.[$k] // empty' "$CONFIG_FILE"
}

config_set() {
  local key="$1" value="$2"
  local tmp_file
  tmp_file=$(mktemp "$CONFIG_DIR/.config.XXXXXX")
  if jq --arg k "$key" --arg v "$value" '.[$k] = $v' "$CONFIG_FILE" > "$tmp_file"; then
    chmod 600 "$tmp_file"
    mv "$tmp_file" "$CONFIG_FILE"
  else
    rm -f "$tmp_file"
    return 1
  fi
}

config_get_host() {
  local host
  if [[ -n "$OPT_DEV" ]]; then
    host="https://moneybird.dev"
  elif [[ -n "${MONEYBIRD_HOST:-}" ]]; then
    host="$MONEYBIRD_HOST"
  else
    host=$(config_get host)
  fi
  echo "${host:-https://moneybird.com}"
}

config_get_admin_id() {
  local admin_id
  if [[ -n "$OPT_ADMINISTRATION" ]]; then
    admin_id="$OPT_ADMINISTRATION"
  else
    admin_id=$(sessions_current_id)
  fi
  if [[ -z "$admin_id" ]]; then
    echo "Error: No administration selected." >&2
    echo "Run: moneybird-cli login <token>" >&2
    return 1
  fi
  echo "$admin_id"
}

# Sessions file per host
config_sessions_file() {
  local host
  host=$(config_get_host)
  local host_slug
  host_slug=$(echo "$host" | sed -E 's|https?://||' | tr './' '__' | tr -cd 'a-zA-Z0-9_-')
  echo "$CONFIG_DIR/sessions_${host_slug}.json"
}

# Ensure sessions file exists
sessions_init() {
  local sessions_file
  sessions_file=$(config_sessions_file)
  if [[ ! -f "$sessions_file" ]]; then
    echo '{"current": null, "sessions": {}}' > "$sessions_file"
    chmod 600 "$sessions_file"
  fi
}

# Get current administration ID from sessions
sessions_current_id() {
  local sessions_file
  sessions_file=$(config_sessions_file)
  [[ -f "$sessions_file" ]] || return 0
  jq -r '.current // empty' "$sessions_file"
}

# Store a session (token + admin info)
sessions_store() {
  local admin_id="$1" admin_name="$2" token_data="$3"
  local sessions_file
  sessions_file=$(config_sessions_file)
  sessions_init

  local tmp_file
  tmp_file=$(mktemp "$CONFIG_DIR/.sessions.XXXXXX")
  if jq --arg id "$admin_id" --arg name "$admin_name" --argjson token "$token_data" '
    .current = $id
    | .sessions[$id] = ($token + {administration_name: $name})
  ' "$sessions_file" > "$tmp_file"; then
    chmod 600 "$tmp_file"
    mv "$tmp_file" "$sessions_file"
  else
    rm -f "$tmp_file"
    return 1
  fi
}

# Remove a session
sessions_remove() {
  local admin_id="$1"
  local sessions_file
  sessions_file=$(config_sessions_file)
  [[ -f "$sessions_file" ]] || return 0

  local tmp_file
  tmp_file=$(mktemp "$CONFIG_DIR/.sessions.XXXXXX")
  if jq --arg id "$admin_id" '
    del(.sessions[$id])
    | if .current == $id then
        .current = (.sessions | keys | first // null)
      else . end
  ' "$sessions_file" > "$tmp_file"; then
    chmod 600 "$tmp_file"
    mv "$tmp_file" "$sessions_file"
  else
    rm -f "$tmp_file"
    return 1
  fi
}

# Remove all sessions
sessions_remove_all() {
  local sessions_file
  sessions_file=$(config_sessions_file)
  rm -f "$sessions_file"
}

# Switch to a different session
sessions_use() {
  local admin_id="$1"
  local sessions_file
  sessions_file=$(config_sessions_file)
  sessions_init

  local exists
  exists=$(jq --arg id "$admin_id" '.sessions | has($id)' "$sessions_file")
  if [[ "$exists" != "true" ]]; then
    echo "Error: No session for administration $admin_id" >&2
    echo "Run: moneybird-cli administration list" >&2
    return 1
  fi

  local tmp_file
  tmp_file=$(mktemp "$CONFIG_DIR/.sessions.XXXXXX")
  if jq --arg id "$admin_id" '.current = $id' "$sessions_file" > "$tmp_file"; then
    chmod 600 "$tmp_file"
    mv "$tmp_file" "$sessions_file"
  else
    rm -f "$tmp_file"
    return 1
  fi
}

# Get token for current session
sessions_get_token() {
  local sessions_file
  sessions_file=$(config_sessions_file)
  [[ -f "$sessions_file" ]] || return 1

  local admin_id
  admin_id=$(jq -r '.current // empty' "$sessions_file")
  [[ -z "$admin_id" ]] && return 1

  jq -r --arg id "$admin_id" '.sessions[$id].access_token // empty' "$sessions_file"
}

# Get token expiry for current session
sessions_get_expires_at() {
  local sessions_file
  sessions_file=$(config_sessions_file)
  [[ -f "$sessions_file" ]] || return 1

  local admin_id
  admin_id=$(jq -r '.current // empty' "$sessions_file")
  [[ -z "$admin_id" ]] && return 1

  jq -r --arg id "$admin_id" '.sessions[$id].expires_at // 0' "$sessions_file"
}

# Update token data for current session (used by refresh)
sessions_update_token() {
  local token_data="$1"
  local sessions_file
  sessions_file=$(config_sessions_file)

  local admin_id
  admin_id=$(jq -r '.current // empty' "$sessions_file")

  local tmp_file
  tmp_file=$(mktemp "$CONFIG_DIR/.sessions.XXXXXX")
  if jq --arg id "$admin_id" --argjson token "$token_data" '
    .sessions[$id] = (.sessions[$id] + $token)
  ' "$sessions_file" > "$tmp_file"; then
    chmod 600 "$tmp_file"
    mv "$tmp_file" "$sessions_file"
  else
    rm -f "$tmp_file"
    return 1
  fi
}

# List all sessions
sessions_list() {
  local sessions_file
  sessions_file=$(config_sessions_file)
  if [[ ! -f "$sessions_file" ]]; then
    echo "No sessions. Run: moneybird-cli login <token>"
    return 0
  fi

  local count
  count=$(jq '.sessions | length' "$sessions_file")
  if [[ "$count" == "0" ]]; then
    echo "No sessions. Run: moneybird-cli login <token>"
    return 0
  fi

  jq -r '
    .current as $cur
    | .sessions | to_entries[]
    | (if .key == $cur then "* " else "  " end)
      + .key + "  " + .value.administration_name
  ' "$sessions_file"
}
