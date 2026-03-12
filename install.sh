#!/usr/bin/env bash
set -euo pipefail

INSTALL_DIR="${MONEYBIRD_CLI_DIR:-$HOME/.moneybird-cli}"
BIN_DIR="/usr/local/bin"

echo "Installing moneybird-cli to $INSTALL_DIR..."

# Check dependencies
for cmd in curl jq; do
  if ! command -v "$cmd" &>/dev/null; then
    echo "Error: $cmd is required. Install with: brew install $cmd" >&2
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

# Symlink to PATH
if [[ -d "$BIN_DIR" && -w "$BIN_DIR" ]]; then
  ln -sf "$INSTALL_DIR/moneybird-cli" "$BIN_DIR/moneybird-cli"
  echo "Linked to $BIN_DIR/moneybird-cli"
else
  echo "Add to your PATH manually:"
  echo "  ln -s $INSTALL_DIR/moneybird-cli /usr/local/bin/moneybird-cli"
  echo "  # or add to your shell profile:"
  echo "  export PATH=\"$INSTALL_DIR:\$PATH\""
fi

echo ""
echo "Done! Run 'moneybird-cli --version' to verify."
