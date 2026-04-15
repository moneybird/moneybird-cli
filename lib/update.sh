#!/usr/bin/env bash
# Version checking and self-update

UPDATE_CHECK_FILE="$CONFIG_DIR/last_update_check"
UPDATE_CHECK_INTERVAL=86400 # 24 hours
UPDATE_AVAILABLE_FILE="$CONFIG_DIR/update_available"

# Check for newer version in background (called on each run)
update_check_background() {
  # Skip if no git repo (manual install)
  [[ -d "$CLI_DIR/.git" ]] || return 0

  # Skip if checked recently
  if [[ -f "$UPDATE_CHECK_FILE" ]]; then
    local mod_time now age
    if [[ "$(uname)" == "Darwin" ]]; then
      mod_time=$(stat -f %m "$UPDATE_CHECK_FILE")
    else
      mod_time=$(stat -c %Y "$UPDATE_CHECK_FILE")
    fi
    now=$(date +%s)
    age=$((now - mod_time))
    (( age < UPDATE_CHECK_INTERVAL )) && return 0
  fi

  # Run check in background
  (update_check_remote &>/dev/null &)
}

# Fetch from remote and check if we're behind
update_check_remote() {
  git -C "$CLI_DIR" fetch --quiet origin main 2>/dev/null || return 0

  local local_sha remote_sha
  local_sha=$(git -C "$CLI_DIR" rev-parse HEAD 2>/dev/null)
  remote_sha=$(git -C "$CLI_DIR" rev-parse origin/main 2>/dev/null)

  if [[ -n "$local_sha" && -n "$remote_sha" && "$local_sha" != "$remote_sha" ]]; then
    local count
    count=$(git -C "$CLI_DIR" rev-list HEAD..origin/main --count 2>/dev/null)
    echo "$count" > "$UPDATE_AVAILABLE_FILE"
  else
    rm -f "$UPDATE_AVAILABLE_FILE"
  fi
  touch "$UPDATE_CHECK_FILE"
}

# Print upgrade hint if we're behind origin/main (called on each run)
update_hint() {
  [[ -f "$UPDATE_AVAILABLE_FILE" ]] || return 0

  local count
  count=$(cat "$UPDATE_AVAILABLE_FILE" 2>/dev/null | tr -d '[:space:]')
  [[ -z "$count" || "$count" == "0" ]] && return 0

  if [[ "$count" == "1" ]]; then
    echo "A new version of moneybird-cli is available (1 commit behind)." >&2
  else
    echo "A new version of moneybird-cli is available ($count commits behind)." >&2
  fi
  echo "Run 'moneybird-cli update' to upgrade." >&2
  echo "" >&2
}

# Self-update via git pull
cmd_update() {
  if [[ ! -d "$CLI_DIR/.git" ]]; then
    echo "Error: Cannot update — not installed via git." >&2
    echo "Re-install with: curl -fsSL https://raw.githubusercontent.com/moneybird/moneybird-cli/main/install.sh | bash" >&2
    exit 1
  fi

  echo "Updating moneybird-cli..."

  local old_sha
  old_sha=$(git -C "$CLI_DIR" rev-parse --short HEAD 2>/dev/null)

  if ! git -C "$CLI_DIR" pull --ff-only 2>&1; then
    echo "" >&2
    echo "Error: Update failed. You may have local changes." >&2
    echo "To force update: cd $CLI_DIR && git reset --hard origin/main && git pull" >&2
    exit 1
  fi

  local new_sha
  new_sha=$(git -C "$CLI_DIR" rev-parse --short HEAD 2>/dev/null)

  if [[ "$old_sha" == "$new_sha" ]]; then
    echo "Already up to date ($old_sha)."
  else
    echo "Updated: $old_sha -> $new_sha"
  fi

  # Clear the cached state so the hint goes away
  rm -f "$UPDATE_AVAILABLE_FILE" "$UPDATE_CHECK_FILE"
}
