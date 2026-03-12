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
    admin_id=$(config_get current_administration_id)
  fi
  if [[ -z "$admin_id" ]]; then
    echo "Error: No administration selected." >&2
    echo "Run: moneybird-cli administrations list" >&2
    echo "Then: moneybird-cli administration use <id>" >&2
    return 1
  fi
  echo "$admin_id"
}

config_tokens_file() {
  local host
  host=$(config_get_host)
  # Sanitize for filename: strip scheme, replace dots/slashes with underscores, keep safe chars
  local host_slug
  host_slug=$(echo "$host" | sed -E 's|https?://||' | tr './' '__' | tr -cd 'a-zA-Z0-9_-')
  echo "$CONFIG_DIR/tokens_${host_slug}.json"
}
