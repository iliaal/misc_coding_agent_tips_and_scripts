#!/usr/bin/env bash
# Regression test for PR #11: an npm-owned Codex install must never be
# downgraded by `uca codex`, and a downgrade must never be reported as an
# update.
#
# Background: npm >= 11 honours `min-release-age` from npmrc and bun honours
# `minimumReleaseAge` from bunfig.toml. Under such a gate an `@latest`
# install does not fail; it quietly resolves to the newest version that is
# old enough, which can be OLDER than the installed one (0.153.2 -> 0.151.0
# was reported), and the old update loop then printed "UPDATED: From version
# 0.153.2 to version 0.151.0".
#
# The test stands up a fake npm-owned codex under an isolated HOME with a
# scripted `npm` that behaves like a gated registry, and drives the real
# `uca codex` end to end. No network, nothing real is touched.
#
# Usage: bash tests/test-uca-codex-registry.sh
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="$(mktemp -d 2>/dev/null || mktemp -d -t uca-codex-test)"
WORK="$(cd "$WORK" && pwd -P)"   # physical path: uca compares realpath()s
trap 'rm -rf "$WORK"' EXIT

fail() { echo "FAIL: $*" >&2; exit 1; }

HOME_DIR="$WORK/home"
BIN_DIR="$HOME_DIR/.local/bin"            # uca puts this first on PATH
NPM_ROOT="$WORK/npmroot"                  # what `npm root -g` reports
CODEX_PKG="$NPM_ROOT/@openai/codex/bin"
mkdir -p "$BIN_DIR" "$CODEX_PKG"

# The "installed" codex: prints whatever version file says.
cat > "$CODEX_PKG/codex" <<EOF
#!/usr/bin/env bash
case "\${1:-}" in
  --version) echo "codex-cli \$(cat "$WORK/codex_version")" ;;
  *) exit 0 ;;
esac
EOF
chmod +x "$CODEX_PKG/codex"
ln -s "$CODEX_PKG/codex" "$BIN_DIR/codex"

# Scripted npm:
#   npm root -g                          -> the fake global root (ownership)
#   npm view @openai/codex dist-tags.latest -> $WORK/registry_latest (ungated)
#   npm install -g @openai/codex@latest ... -> logs its argv; installs
#       $WORK/registry_latest when the age gate is overridden
#       (--min-release-age=0), otherwise $WORK/gated_version, i.e. what a
#       7-day min-release-age would pick. $WORK/force_version, when present,
#       wins regardless (a package manager that downgrades no matter what).
cat > "$BIN_DIR/npm" <<EOF
#!/usr/bin/env bash
case "\${1:-} \${2:-}" in
  "root -g") echo "$NPM_ROOT" ;;
  "view @openai/codex") cat "$WORK/registry_latest" ;;
  "install -g")
    printf '%s\n' "\$*" >> "$WORK/npm.log"
    if [ -f "$WORK/force_version" ]; then
      cat "$WORK/force_version" > "$WORK/codex_version"
    elif [[ " \$* " == *" --min-release-age=0 "* ]]; then
      cat "$WORK/registry_latest" > "$WORK/codex_version"
    else
      cat "$WORK/gated_version" > "$WORK/codex_version"
    fi
    ;;
esac
exit 0
EOF
chmod +x "$BIN_DIR/npm"

# Keep bun out of the picture so ownership can only classify as npm.
cat > "$BIN_DIR/bun" <<'EOF'
#!/usr/bin/env bash
echo "bun should not be invoked for an npm-owned codex: $*" >&2
exit 97
EOF
chmod +x "$BIN_DIR/bun"

run_uca() {  # run_uca LABEL INSTALLED REGISTRY_LATEST GATED [FORCE]
  local label="$1" installed="$2" latest="$3" gated="$4" force="${5:-}"
  echo "$installed" > "$WORK/codex_version"
  echo "$latest"    > "$WORK/registry_latest"
  echo "$gated"     > "$WORK/gated_version"
  rm -f "$WORK/force_version" "$WORK/npm.log"
  [ -n "$force" ] && echo "$force" > "$WORK/force_version"
  RC=0
  OUT="$WORK/$label.out"
  (
    export HOME="$HOME_DIR" XDG_DATA_HOME="$HOME_DIR/.local/share" XDG_CONFIG_HOME="$HOME_DIR/.config"
    export PATH="$BIN_DIR:$PATH" NO_COLOR=1
    "$ROOT/uca" codex --no-gum --ignore-disk-space
  ) >"$OUT" 2>&1 || RC=$?
  echo "== $label: exit=$RC, codex now $(cat "$WORK/codex_version"), npm installs=$(grep -c '' "$WORK/npm.log" 2>/dev/null || echo 0)"
}

# 1. Registry has a newer release than what is installed but the age gate
#    would hand back an older one: uca must override the gate and end up on
#    the registry's latest.
run_uca gated-upgrade 0.153.2 0.153.4 0.151.0
[ "$RC" -eq 0 ] || { cat "$OUT"; fail "gated-upgrade exited $RC"; }
[ "$(cat "$WORK/codex_version")" = "0.153.4" ] || { cat "$OUT"; fail "gated-upgrade: expected 0.153.4, got $(cat "$WORK/codex_version")"; }
grep -q -- '--min-release-age=0' "$WORK/npm.log" || fail "gated-upgrade: npm install was not told to ignore min-release-age"
grep -q -- '--prefer-online' "$WORK/npm.log" || fail "gated-upgrade: npm install was not told to refresh the packument cache"
grep -q 'UPDATED' "$OUT" || { cat "$OUT"; fail "gated-upgrade: 0.153.2 -> 0.153.4 was not reported as UPDATED"; }
grep -q '0.153.2.*0.153.4' "$OUT" || { cat "$OUT"; fail "gated-upgrade: version transition missing from output"; }

# 2. The registry's `latest` tag is BEHIND the installed version (tag moved
#    back, or a wrong registry): uca must not touch the install at all.
run_uca registry-behind 0.153.2 0.151.0 0.151.0
[ "$RC" -eq 0 ] || { cat "$OUT"; fail "registry-behind exited $RC"; }
[ ! -f "$WORK/npm.log" ] || { cat "$OUT"; fail "registry-behind: npm install was invoked: $(cat "$WORK/npm.log")"; }
[ "$(cat "$WORK/codex_version")" = "0.153.2" ] || fail "registry-behind: install was changed"
grep -q 'older than the installed 0.153.2' "$OUT" || { cat "$OUT"; fail "registry-behind: no explanation printed"; }
grep -q 'Up to date' "$OUT" || { cat "$OUT"; fail "registry-behind: not reported as up to date"; }
if grep -q 'UPDATED' "$OUT"; then cat "$OUT"; fail "registry-behind: reported as UPDATED"; fi

# 3. The package manager downgrades anyway (flags ignored, stale mirror):
#    the loop must say DOWNGRADED and fail the run, never "UPDATED".
run_uca downgrade-anyway 0.153.2 0.153.4 0.151.0 0.151.0
[ "$RC" -ne 0 ] || { cat "$OUT"; fail "downgrade-anyway: run succeeded"; }
grep -q 'DOWNGRADED' "$OUT" || { cat "$OUT"; fail "downgrade-anyway: DOWNGRADED not reported"; }
grep -q 'a DOWNGRADE' "$OUT" || { cat "$OUT"; fail "downgrade-anyway: codex-specific diagnosis missing"; }
if grep -q 'UPDATED' "$OUT"; then cat "$OUT"; fail "downgrade-anyway: reported as UPDATED"; fi
grep -q '"last_status": "error"' "$HOME_DIR/.local/share/uca/state.json" || fail "downgrade-anyway: state.json does not record the error"

# 4. Already current: leave the executable available to running sessions.
run_uca current 0.153.4 0.153.4 0.153.4
[ "$RC" -eq 0 ] || { cat "$OUT"; fail "current exited $RC"; }
grep -q 'Up to date' "$OUT" || { cat "$OUT"; fail "current: not reported as up to date"; }
[[ ! -f ${WORK}/npm.log ]] || fail "current: npm install must not replace the current executable"

run_uca registry-unavailable 0.153.2 '' 0.151.0 0.153.4
[[ ${RC} == 0 ]] || { cat "${OUT}"; fail "registry-unavailable exited ${RC}"; }
[[ -f ${WORK}/npm.log ]] || fail "registry-unavailable: missing registry version must not skip installation"
read -r active_version <"${WORK}/codex_version"
[[ ${active_version} == 0.153.4 ]] || fail "registry-unavailable: upgrade did not run"

# 5. version_lt ordering, exercised in-process (uca's functions, main stripped).
vlt() {
  ( export HOME="$HOME_DIR"; set +u
    # shellcheck disable=SC1090
    source <(grep -v '^main "\$@"$' "$ROOT/uca")
    version_lt "$1" "$2" )
}
expect_lt()  { vlt "$1" "$2" || fail "version_lt: expected $1 < $2"; }
expect_nlt() { if vlt "$1" "$2"; then fail "version_lt: expected NOT $1 < $2"; fi; }
expect_lt  0.151.0 0.153.2
expect_lt  0.153.2 0.153.4
expect_lt  1.2.9   1.2.10
expect_lt  1.9     1.10.0
expect_lt  2.0.0-rc.1 2.0.0
expect_lt  2.0.0-alpha 2.0.0-beta
expect_lt  1.0.0+build.5 1.0.1
expect_nlt 0.153.4 0.153.2
expect_nlt 0.153.4 0.153.4
expect_nlt 1.0     1.0.0
expect_nlt 2.0.0   2.0.0-rc.1
expect_nlt unknown 1.0.0
expect_nlt 1.0.0   unknown
echo "== version_lt: 13 orderings OK"

echo "OK: npm-owned codex is never downgraded and a downgrade is never reported as an update"
