#!/usr/bin/env bash
set -euo pipefail

INSTALL_DIR="${MONEYBIRD_CLI_DIR:-$HOME/.moneybird-cli}"

echo "Installing moneybird-cli to $INSTALL_DIR..."

# Check dependencies
for cmd in curl jq git; do
  if ! command -v "$cmd" &>/dev/null; then
    echo "Error: $cmd is required. Install with: brew install $cmd (macOS) or sudo apt-get install $cmd (Debian/Ubuntu)" >&2
    exit 1
  fi
done

# Clone or update
if [[ -d "$INSTALL_DIR" ]]; then
  echo "Updating existing installation..."
  git -C "$INSTALL_DIR" pull --ff-only
else
  git clone https://github.com/moneybird/moneybird-cli.git "$INSTALL_DIR"
fi

chmod +x "$INSTALL_DIR/moneybird-cli"

# Symlink to PATH — try writable locations in order of preference
link_target=""
for bin_dir in /usr/local/bin "$HOME/.local/bin"; do
  if [[ -d "$bin_dir" && -w "$bin_dir" ]]; then
    link_target="$bin_dir"
    break
  fi
done

# If ~/.local/bin doesn't exist yet, create it (common on Linux)
if [[ -z "$link_target" && ! -d "$HOME/.local/bin" ]]; then
  mkdir -p "$HOME/.local/bin"
  link_target="$HOME/.local/bin"
fi

if [[ -n "$link_target" ]]; then
  ln -sf "$INSTALL_DIR/moneybird-cli" "$link_target/moneybird-cli"
  echo "Linked to $link_target/moneybird-cli"

  # Check if the bin dir is in PATH
  if ! echo "$PATH" | tr ':' '\n' | grep -qx "$link_target"; then
    echo ""
    echo "Note: $link_target is not in your PATH. Add it with:"
    echo "  export PATH=\"$link_target:\$PATH\""
  fi
else
  echo "Add to your PATH manually:"
  echo "  ln -s $INSTALL_DIR/moneybird-cli /usr/local/bin/moneybird-cli"
  echo "  # or add to your shell profile:"
  echo "  export PATH=\"$INSTALL_DIR:\$PATH\""
fi

# Handle --config-dir flag
config_dir=""
for arg in "$@"; do
  case "$arg" in
    --config-dir=*) config_dir="${arg#--config-dir=}" ;;
  esac
done

echo ""
echo "Done! Run 'moneybird-cli --version' to verify."

if [[ -n "$config_dir" ]]; then
  echo ""
  echo "To use config from $config_dir, set:"
  echo "  export MONEYBIRD_CONFIG_DIR=\"$config_dir\""
elif [[ -n "${MONEYBIRD_CONFIG_DIR:-}" ]]; then
  echo ""
  echo "Using config directory: $MONEYBIRD_CONFIG_DIR"
fi
