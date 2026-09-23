#!/usr/bin/env bash
# Regression test for OpenCode support: `uca opencode` must update an npm- or
# bun-owned install with the same release-age-gate overrides as codex, never
# downgrade it, and hand a curl-installer install to `opencode upgrade`.
#
# OpenCode ships as the npm package `opencode-ai`; its own installer
# (curl -fsSL https://opencode.ai/install | bash) puts the binary in
# ~/.opencode/bin. bun links ~/.bun/bin/opencode into
# ~/.bun/install/global/node_modules, so bun ownership has to be recognised
# from a realpath outside ~/.bun/bin.
#
# The test stands up fake installs under an isolated HOME with scripted `npm`
# and `bun` that behave like a gated registry, and drives the real
# `uca opencode` end to end. No network, nothing real is touched.
#
# Usage: bash tests/test-uca-opencode.sh
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="$(mktemp -d 2>/dev/null || mktemp -d -t uca-opencode-test)"
WORK="$(cd "$WORK" && pwd -P)"   # physical path: uca compares realpath()s
trap 'rm -rf "$WORK"' EXIT

fail() { echo "FAIL: $*" >&2; exit 1; }

HOME_DIR="$WORK/home"
BIN_DIR="$HOME_DIR/.local/bin"
TOOLS="$WORK/tools"                       # scripted npm / bun, never in HOME
NPM_ROOT="$WORK/npmroot"
NPM_PKG="$NPM_ROOT/opencode-ai/bin"
BUN_PKG="$HOME_DIR/.bun/install/global/node_modules/opencode-ai/bin"
CURL_BIN="$HOME_DIR/.opencode/bin"
mkdir -p "$BIN_DIR" "$TOOLS" "$NPM_PKG" "$BUN_PKG" "$HOME_DIR/.bun/bin" "$CURL_BIN"

# One fake opencode for every layout: prints the version file; `upgrade`
# logs that it ran and installs $WORK/registry_latest.
for dir in "$NPM_PKG" "$BUN_PKG" "$CURL_BIN"; do
  cat > "$dir/opencode" <<EOF
#!/usr/bin/env bash
case "\${1:-}" in
  --version|-v) cat "$WORK/opencode_version" ;;
  upgrade) echo "\$0 \$*" >> "$WORK/self.log"; cat "$WORK/registry_latest" > "$WORK/opencode_version" ;;
  *) exit 0 ;;
esac
EOF
  chmod +x "$dir/opencode"
done

# Scripted package managers. `install -g` logs its argv and installs
# $WORK/registry_latest only when the age gate is overridden, otherwise
# $WORK/gated_version (what a 7-day release-age gate would pick).
cat > "$TOOLS/npm" <<EOF
#!/usr/bin/env bash
case "\${1:-} \${2:-}" in
  "root -g") echo "$NPM_ROOT" ;;
  "view opencode-ai") cat "$WORK/registry_latest" ;;
  "install -g")
    printf 'npm %s\n' "\$*" >> "$WORK/pm.log"
    if [[ " \$* " == *" --min-release-age=0 "* ]]; then
      cat "$WORK/registry_latest" > "$WORK/opencode_version"
    else
      cat "$WORK/gated_version" > "$WORK/opencode_version"
    fi
    ;;
esac
exit 0
EOF
cat > "$TOOLS/bun" <<EOF
#!/usr/bin/env bash
case "\${1:-} \${2:-}" in
  "info opencode-ai") cat "$WORK/registry_latest" ;;
  "install -g")
    printf 'bun %s\n' "\$*" >> "$WORK/pm.log"
    if [[ " \$* " == *" --minimum-release-age=0 "* ]]; then
      cat "$WORK/registry_latest" > "$WORK/opencode_version"
    else
      cat "$WORK/gated_version" > "$WORK/opencode_version"
    fi
    ;;
esac
exit 0
EOF
chmod +x "$TOOLS/npm" "$TOOLS/bun"

use_layout() {  # use_layout npm|bun|curl — point the active `opencode` at one install
  rm -f "$BIN_DIR/opencode" "$HOME_DIR/.bun/bin/opencode"
  case "$1" in
    npm)  ln -s "$NPM_PKG/opencode" "$BIN_DIR/opencode" ;;
    bun)  ln -s "../install/global/node_modules/opencode-ai/bin/opencode" "$HOME_DIR/.bun/bin/opencode" ;;
    curl) : ;;  # found via ~/.opencode/bin, which is not on PATH
  esac
}

run_uca() {  # run_uca LABEL INSTALLED REGISTRY_LATEST GATED
  local label="$1"
  echo "$2" > "$WORK/opencode_version"
  echo "$3" > "$WORK/registry_latest"
  echo "$4" > "$WORK/gated_version"
  rm -f "$WORK/pm.log" "$WORK/self.log"
  RC=0
  OUT="$WORK/$label.out"
  (
    export HOME="$HOME_DIR" XDG_DATA_HOME="$HOME_DIR/.local/share" XDG_CONFIG_HOME="$HOME_DIR/.config"
    # Fixed PATH: the developer's own opencode / npm must not leak in.
    export PATH="$BIN_DIR:$HOME_DIR/.bun/bin:$TOOLS:/usr/local/bin:/usr/bin:/bin" NO_COLOR=1
    "$ROOT/uca" opencode --no-gum --ignore-disk-space
  ) >"$OUT" 2>&1 || RC=$?
  echo "== $label: exit=$RC, opencode now $(cat "$WORK/opencode_version"), pm installs=$(grep -c '' "$WORK/pm.log" 2>/dev/null || echo 0)"
}

# 1. npm-owned, gate would pick an older build: uca overrides the gate.
use_layout npm
run_uca npm-gated 1.18.31 1.18.32 1.18.20
[ "$RC" -eq 0 ] || { cat "$OUT"; fail "npm-gated exited $RC"; }
[ "$(cat "$WORK/opencode_version")" = "1.18.32" ] || { cat "$OUT"; fail "npm-gated: expected 1.18.32"; }
grep -q -- 'npm install -g opencode-ai@latest --prefer-online --min-release-age=0' "$WORK/pm.log" || fail "npm-gated: wrong npm invocation: $(cat "$WORK/pm.log")"
grep -q 'UPDATED' "$OUT" || { cat "$OUT"; fail "npm-gated: not reported as UPDATED"; }
grep -A3 '"opencode": {' "$HOME_DIR/.local/share/uca/state.json" | grep -q '"current_version": "1.18.32"' || fail "npm-gated: state.json did not record 1.18.32"

# 2. npm registry `latest` behind the installed version: install untouched.
run_uca npm-behind 1.18.32 1.18.31 1.18.31
[ "$RC" -eq 0 ] || { cat "$OUT"; fail "npm-behind exited $RC"; }
[ ! -f "$WORK/pm.log" ] || fail "npm-behind: npm install was invoked: $(cat "$WORK/pm.log")"
grep -q 'older than the installed 1.18.32' "$OUT" || { cat "$OUT"; fail "npm-behind: no explanation printed"; }

# 3. bun-owned (realpath under ~/.bun/install/global): bun gets the override flags.
use_layout bun
run_uca bun-gated 1.18.31 1.18.32 1.18.20
[ "$RC" -eq 0 ] || { cat "$OUT"; fail "bun-gated exited $RC"; }
grep -q -- 'bun install -g opencode-ai@latest --minimum-release-age=0 --no-cache' "$WORK/pm.log" || fail "bun-gated: wrong bun invocation: $(cat "$WORK/pm.log" 2>/dev/null)"
[ ! -f "$WORK/self.log" ] || fail "bun-gated: opencode upgrade ran for a bun-owned install"
[ "$(cat "$WORK/opencode_version")" = "1.18.32" ] || { cat "$OUT"; fail "bun-gated: expected 1.18.32"; }

# 4. curl installer (~/.opencode/bin, not on PATH): its own `opencode upgrade`.
use_layout curl
run_uca curl 1.18.31 1.18.32 1.18.32
[ "$RC" -eq 0 ] || { cat "$OUT"; fail "curl exited $RC"; }
[ ! -f "$WORK/pm.log" ] || fail "curl: a package manager was invoked: $(cat "$WORK/pm.log")"
grep -q "$CURL_BIN/opencode upgrade" "$WORK/self.log" || fail "curl: opencode upgrade was not invoked"
grep -q 'UPDATED' "$OUT" || { cat "$OUT"; fail "curl: not reported as UPDATED"; }

echo "OK: opencode updates through its owner with the release-age gate overridden and never downgrades"
