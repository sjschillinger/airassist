#!/usr/bin/env bash
#
# Install the `airassist` CLI to ~/.local/bin (or $1) and seed shell
# completions for the user's current shell. Builds Debug if no binary
# is found. Idempotent — safe to re-run after `git pull`.
#
# Usage:
#   scripts/install-cli.sh                # install to ~/.local/bin
#   scripts/install-cli.sh /usr/local/bin # install elsewhere (may need sudo)
#   scripts/install-cli.sh --uninstall    # remove the binary + completions

set -euo pipefail

DEFAULT_BIN_DIR="$HOME/.local/bin"
ACTION="install"
TARGET_DIR=""

for arg in "$@"; do
    case "$arg" in
        --uninstall) ACTION="uninstall" ;;
        --help|-h)
            sed -n '2,12p' "$0" | sed 's/^# \{0,1\}//'
            exit 0 ;;
        /*) TARGET_DIR="$arg" ;;
        *)
            echo "install-cli.sh: unrecognized arg '$arg'" >&2
            exit 64 ;;
    esac
done

BIN_DIR="${TARGET_DIR:-$DEFAULT_BIN_DIR}"

if [[ "$ACTION" == "uninstall" ]]; then
    rm -fv "$BIN_DIR/airassist" 2>/dev/null || true
    # Completions live under user-shell-specific paths; remove all known.
    rm -fv "$HOME/.zsh/completions/_airassist" 2>/dev/null || true
    rm -fv "$HOME/.local/share/bash-completion/completions/airassist" 2>/dev/null || true
    rm -fv "$HOME/.config/fish/completions/airassist.fish" 2>/dev/null || true
    echo "airassist CLI uninstalled."
    exit 0
fi

# Find a built binary. Prefer Release (no debug overhead, smaller) but
# fall back to Debug, then build if neither exists.
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DERIVED_GLOB=("$HOME/Library/Developer/Xcode/DerivedData/AirAssist-"*"/Build/Products")
BIN=""
for dd in "${DERIVED_GLOB[@]}"; do
    for cfg in Release Debug; do
        candidate="$dd/$cfg/airassist"
        if [[ -f "$candidate" ]]; then
            BIN="$candidate"
            break 2
        fi
    done
done

if [[ -z "$BIN" ]]; then
    echo "No built airassist binary found. Building Debug..."
    cd "$ROOT"
    xcodebuild -project AirAssist.xcodeproj -scheme AirAssist \
               -configuration Debug -destination 'platform=macOS' \
               -target AirAssistCLI build >/dev/null
    for dd in "${DERIVED_GLOB[@]}"; do
        if [[ -f "$dd/Debug/airassist" ]]; then
            BIN="$dd/Debug/airassist"
            break
        fi
    done
fi

if [[ -z "$BIN" || ! -f "$BIN" ]]; then
    echo "Build did not produce airassist binary." >&2
    exit 1
fi

mkdir -p "$BIN_DIR"
cp -f "$BIN" "$BIN_DIR/airassist"
chmod +x "$BIN_DIR/airassist"
echo "Installed: $BIN_DIR/airassist"

# Seed completion for the current shell. We don't try to be clever
# about modifying rc files — just drop the file in the conventional
# location and tell the user how to activate it if it isn't already.
SHELL_NAME="${SHELL##*/}"
INSTALLED_BIN="$BIN_DIR/airassist"
case "$SHELL_NAME" in
    zsh)
        DEST="$HOME/.zsh/completions/_airassist"
        mkdir -p "$(dirname "$DEST")"
        "$INSTALLED_BIN" completions zsh > "$DEST"
        echo "zsh completion installed: $DEST"
        echo "  If completion isn't picked up, ensure ~/.zsh/completions is on \$fpath:"
        echo "    fpath=(~/.zsh/completions \$fpath)"
        echo "    autoload -Uz compinit && compinit"
        ;;
    bash)
        DEST="$HOME/.local/share/bash-completion/completions/airassist"
        mkdir -p "$(dirname "$DEST")"
        "$INSTALLED_BIN" completions bash > "$DEST"
        echo "bash completion installed: $DEST"
        ;;
    fish)
        DEST="$HOME/.config/fish/completions/airassist.fish"
        mkdir -p "$(dirname "$DEST")"
        "$INSTALLED_BIN" completions fish > "$DEST"
        echo "fish completion installed: $DEST"
        ;;
    *)
        echo "Unknown shell '$SHELL_NAME' — skipping completion install."
        echo "Run \`airassist completions <zsh|bash|fish>\` and place the output in your shell's completions dir."
        ;;
esac

# PATH check — non-fatal, just a heads-up.
case ":$PATH:" in
    *":$BIN_DIR:"*) ;;
    *)
        echo ""
        echo "Note: $BIN_DIR is not on your \$PATH. Add it to your shell rc:"
        echo "    export PATH=\"$BIN_DIR:\$PATH\""
        ;;
esac
