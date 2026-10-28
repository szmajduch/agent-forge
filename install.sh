#!/usr/bin/env bash
# Links forge-* commands into ~/.local/bin and checks dependencies.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
DEST="${FORGE_BIN_DIR:-$HOME/.local/bin}"
mkdir -p "$DEST"
chmod +x "$HERE"/bin/forge-* "$HERE"/install.sh
for f in "$HERE"/bin/forge-*; do
  [[ "$f" == *.sh ]] && continue
  rm -f "$DEST/$(basename "$f")"
  printf '#!/usr/bin/env bash\nexec "%s" "$@"\n' "$f" > "$DEST/$(basename "$f")"
  chmod +x "$DEST/$(basename "$f")"
done
echo "installed forge-* launchers into $DEST"
case ":$PATH:" in *":$DEST:"*) ;; *) echo "add to your shell rc:  export PATH=\"$DEST:\$PATH\"";; esac

echo; echo "dependencies:"
for c in git tmux jq python3 claude codex; do
  if command -v "$c" >/dev/null; then echo "  ok       $c"; else echo "  MISSING  $c"; fi
done
for c in cloudflared lemux; do
  if command -v "$c" >/dev/null; then echo "  ok       $c (optional)"; else echo "  -        $c (optional)"; fi
done
cat <<'EOF'

macOS install hints:
  brew install tmux jq git python
  npm i -g @anthropic-ai/claude-code @openai/codex
  brew install cloudflared                 # optional
EOF
