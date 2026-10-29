#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SUBJECT="${UCA_TEST_SUBJECT:-${ROOT}/uca}"
WORK=$(mktemp -d)
trap 'rm -rf -- "${WORK}"' EXIT
mkdir -p "${WORK}/home/.local/bin"
BIN="${WORK}/home/.local/bin"

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

for directory in /usr/local/bin /usr/bin /bin /opt/homebrew/bin; do
  for tool in claude codex agy grok omp rtk cursor-agent agent opencode; do
    [[ ! -x ${directory}/${tool} ]] || fail "cannot isolate globally installed harness ${directory}/${tool}"
  done
done

for tool in claude codex agy grok omp rtk cursor-agent agent opencode npm bun curl; do
  cat >"${BIN}/${tool}" <<'EOF'
#!/usr/bin/env bash
printf '%s %s\n' "${0##*/}" "$*" >>"${UCA_TEST_WORK}/calls"
case "${1:-}" in
  --version) printf '1.0.0\n' ;;
  *) exit 99 ;;
esac
EOF
  chmod +x "${BIN}/${tool}"
done
FIXTURE_ENV=(env HOME="${WORK}/home" XDG_DATA_HOME="${WORK}/data" XDG_CONFIG_HOME="${WORK}/config"
  UCA_TEST_WORK="${WORK}" PATH="${BIN}:/usr/local/bin:/usr/bin:/bin:/opt/homebrew/bin" NO_COLOR=1)

reject() {
  local rc=0
  rm -f "${WORK}/calls"
  "${FIXTURE_ENV[@]}" bash "${SUBJECT}" "$@" >"${WORK}/out" 2>&1 || rc=$?
  [[ ${rc} == 2 ]] || {
    cat "${WORK}/out"
    fail "expected exit 2 for $*, got ${rc}"
  }
  grep -q 'no update was run' "${WORK}/out" || fail "missing refusal for $*"
  [[ ! -e ${WORK}/calls ]] || {
    cat "${WORK}/calls"
    fail "harness or network invoked for $*"
  }
  [[ ! -e ${WORK}/data/uca/state.json ]] || fail "state changed for $*"
}

reject --version
reject --dryrun
reject claud
reject claude --no-gum --bogus
reject --dry-run --unknown
reject --min-disk-mb
reject --min-disk-mb --dry-run
reject --min-disk-mb=bad
reject --min-disk-mb=-1

"${FIXTURE_ENV[@]}" bash "${SUBJECT}" --help >"${WORK}/out" 2>&1
grep -q 'Usage:' "${WORK}/out" || fail 'help unavailable'
[[ ! -e ${WORK}/calls ]] || fail 'help invoked harnesses'

for threshold in '--min-disk-mb=0' '--min-disk-mb 0'; do
  read -r -a args <<<"${threshold}"
  "${FIXTURE_ENV[@]}" bash "${SUBJECT}" claude --dry-run --no-gum --json "${args[@]}" >"${WORK}/out" 2>&1
  grep -q '\[DRY-RUN\].*Current: 1.0.0' "${WORK}/out" || {
    cat "${WORK}/out"
    fail 'valid update arguments rejected'
  }
done
if grep -Ev '^claude --version$' "${WORK}/calls"; then fail 'dry run invoked an updater or network'; fi
printf 'PASS: CLI rejects unknown arguments before probing or updating; valid dry runs and help work\n'
