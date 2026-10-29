#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SUBJECT="${UCA_TEST_SUBJECT:-${ROOT}/uca}"
WORK=$(mktemp -d)
trap 'rm -rf -- "${WORK}"' EXIT
mkdir -p "${WORK}/home" "${WORK}/bin" "${WORK}/deleted"

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

for directory in /usr/local/bin /usr/bin /bin /opt/homebrew/bin; do
  [[ ! -x ${directory}/claude ]] || fail "cannot isolate globally installed harness ${directory}/claude"
done

cat >"${WORK}/bin/claude" <<'EOF'
#!/usr/bin/env python3
import os
import sys
from pathlib import Path

Path(os.environ['UCA_TEST_WORK'], 'probe-cwd').write_text(os.getcwd())
if sys.argv[1:] != ['--version']:
    raise SystemExit('unexpected updater invocation')
print('2.1.0')
EOF
chmod +x "${WORK}/bin/claude"
FIXTURE_ENV=(env XDG_DATA_HOME="${WORK}/data" XDG_CONFIG_HOME="${WORK}/config"
  UCA_TEST_WORK="${WORK}" PATH="${WORK}/bin:/usr/local/bin:/usr/bin:/bin:/opt/homebrew/bin" NO_COLOR=1)

(
  cd "${WORK}/deleted"
  rmdir "${WORK}/deleted"
  "${FIXTURE_ENV[@]}" HOME="${WORK}/home" bash "${SUBJECT}" claude --dry-run --no-gum --ignore-disk-space
) >"${WORK}/deleted.out" 2>&1
grep -q '\[DRY-RUN\].*Current: 2.1.0' "${WORK}/deleted.out" || {
  cat "${WORK}/deleted.out"
  fail 'version probe failed from deleted cwd'
}
probe_cwd=$(cat "${WORK}/probe-cwd")
[[ ${probe_cwd} == "${WORK}/home" ]] || fail 'probe did not run from HOME'

rm "${WORK}/probe-cwd"
"${FIXTURE_ENV[@]}" HOME="${WORK}/missing-home" bash "${SUBJECT}" claude --dry-run --no-gum --ignore-disk-space >"${WORK}/fallback.out" 2>&1
grep -q '\[DRY-RUN\].*Current: 2.1.0' "${WORK}/fallback.out" || {
  cat "${WORK}/fallback.out"
  fail 'version probe failed with unavailable HOME'
}
probe_cwd=$(cat "${WORK}/probe-cwd")
[[ ${probe_cwd} == / ]] || fail 'probe did not fall back to /'
printf 'PASS: deleted cwd and unavailable HOME recover before version probes\n'
