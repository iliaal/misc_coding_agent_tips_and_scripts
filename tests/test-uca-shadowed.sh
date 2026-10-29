#!/usr/bin/env bash
set -euo pipefail
shopt -s inherit_errexit

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SUBJECT="${UCA_TEST_SUBJECT:-${ROOT}/uca}"
WORK=$(mktemp -d)
trap 'rm -rf -- "${WORK}"' EXIT
TIMEOUT=$(command -v timeout || command -v gtimeout)
CASE_HOME=""
ACTIVE=""
SHADOW=""
THIRD=""
OUT=""
CALLS=""
CASES=0

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  [[ ! -f ${OUT} ]] || cat "${OUT}" >&2
  exit 1
}

new_case() {
  CASE_HOME="${WORK}/$1/home"
  ACTIVE="${CASE_HOME}/.local/bin"
  SHADOW="${WORK}/$1/shadow bins"
  THIRD="${WORK}/$1/third"
  CALLS="${WORK}/$1/calls"
  OUT="${WORK}/$1/output"
  mkdir -p "${ACTIVE}" "${SHADOW}" "${THIRD}"
  local tool
  for tool in claude codex agy grok omp rtk cursor-agent agent opencode npm bun; do
    printf '#!/usr/bin/env bash\nexit 127\n' >"${ACTIVE}/${tool}"
    chmod +x "${ACTIVE}/${tool}"
  done
  cat >"${ACTIVE}/curl" <<'EOF'
#!/usr/bin/env bash
case "${!#}" in
  https://api.github.com/repos/can1357/oh-my-pi/releases/latest) printf '{"tag_name":"v1.0.0"}\n' ;;
  https://api.github.com/repos/rtk-ai/rtk/releases/latest) printf '{"tag_name":"v1.0.0"}\n' ;;
  *) printf 'forbidden network: %s\n' "$*" >>"${UCA_TEST_CALLS}"; exit 64 ;;
esac
EOF
  chmod +x "${ACTIVE}/curl"
  : >"${CALLS}"
}

make_probe() {
  local path="$1" version="$2" mode="${3:-ok}"
  mkdir -p "${path%/*}"
  cat >"${path}" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%s|%s\n' "$0" "$*" >>"${UCA_TEST_CALLS}"
[[ ${1:-} == --version ]] || exit 64
real=$(readlink -f "$0")
case "$(cat "${real}.mode")" in
  fail) cat "${real}.version"; exit 1 ;;
  hang) sleep 30 ;;
  *) cat "${real}.version" ;;
esac
EOF
  printf '%s\n' "${version}" >"${path}.version"
  printf '%s\n' "${mode}" >"${path}.mode"
  chmod +x "${path}"
}

run_uca() {
  local rc=0
  "${TIMEOUT}" -k 1 15 env HOME="${CASE_HOME}" \
    XDG_DATA_HOME="${CASE_HOME}/.local/share" XDG_CONFIG_HOME="${CASE_HOME}/.config" \
    PATH="${ACTIVE}:${SHADOW}:${THIRD}:/usr/local/bin:/usr/bin:/bin" \
    UCA_TEST_CALLS="${CALLS}" NO_COLOR=1 \
    "${SUBJECT}" "$@" --dry-run --no-gum --ignore-disk-space >"${OUT}" 2>&1 || rc=$?
  [[ ${rc} == 0 ]] || fail "UCA exited ${rc}"
  if grep -q 'forbidden network' "${CALLS}"; then fail 'unexpected network request'; fi
  if grep -Ev '\|--version$' "${CALLS}"; then fail 'a harness received an update or another non-version command'; fi
  CASES=$((CASES + 1))
}

assert_warning() {
  grep -qi shadow "${OUT}" || fail 'shadow warning missing'
  grep -Fq "$1" "${OUT}" || fail "active path missing: $1"
  grep -Fq "$2" "${OUT}" || fail "newer path missing: $2"
  grep -Fq "$3" "${OUT}" || fail "active version missing: $3"
  grep -Fq "$4" "${OUT}" || fail "newer version missing: $4"
}

assert_no_warning() {
  if grep -qi shadow "${OUT}"; then fail 'unexpected shadow warning'; fi
}

main() {
  local directory tool version
  for directory in /usr/local/bin /usr/bin /bin /opt/homebrew/bin; do
    for tool in claude codex agy grok omp rtk cursor-agent agent opencode; do
      [[ ! -x ${directory}/${tool} ]] || fail "cannot isolate globally installed harness ${directory}/${tool}"
    done
  done

  new_case newest
  make_probe "${ACTIVE}/codex" 1.0.0
  make_probe "${SHADOW}/codex" 2.0.0
  make_probe "${THIRD}/codex" 3.0.0
  run_uca codex
  assert_warning "${ACTIVE}/codex" "${THIRD}/codex" 1.0.0 3.0.0
  if grep -Fq "${SHADOW}/codex" "${OUT}"; then fail 'reported a candidate that was not the newest'; fi

  for version in 1.0.0 0.9.0; do
    new_case "not-newer-${version}"
    make_probe "${ACTIVE}/codex" 1.0.0
    make_probe "${SHADOW}/codex" "${version}"
    run_uca codex
    assert_no_warning
  done

  new_case symlink
  make_probe "${ACTIVE}/codex" 1.0.0
  ln -s "${ACTIVE}/codex" "${SHADOW}/codex"
  run_uca codex
  assert_no_warning
  if grep -Fq "${SHADOW}/codex|" "${CALLS}"; then fail 'duplicate realpath was probed'; fi

  new_case quiet
  make_probe "${ACTIVE}/codex" 1.0.0
  make_probe "${SHADOW}/codex" 2.0.0
  run_uca codex --quiet
  assert_no_warning
  if grep -Fq "${SHADOW}/codex|" "${CALLS}"; then fail 'quiet run probed an extra binary'; fi

  new_case failed-probe
  make_probe "${ACTIVE}/codex" 1.0.0
  make_probe "${SHADOW}/codex" 9.0.0 fail
  run_uca codex
  assert_no_warning
  grep -Fq "${SHADOW}/codex|--version" "${CALLS}" || fail 'failed probe was never exercised'

  new_case timed-out-probe
  make_probe "${ACTIVE}/codex" 1.0.0
  make_probe "${SHADOW}/codex" 9.0.0 hang
  run_uca codex
  assert_no_warning
  grep -Fq "${SHADOW}/codex|--version" "${CALLS}" || fail 'hanging probe was never exercised'

  new_case cursor-newer
  make_probe "${ACTIVE}/cursor-agent" 2026.09.10-ffffff
  make_probe "${SHADOW}/cursor-agent" 2026.09.11-000000
  run_uca cursor
  assert_warning "${ACTIVE}/cursor-agent" "${SHADOW}/cursor-agent" 2026.09.10-ffffff 2026.09.11-000000

  new_case cursor-same-day
  make_probe "${ACTIVE}/cursor-agent" 2026.09.10-000000
  make_probe "${SHADOW}/cursor-agent" 2026.09.10-ffffff
  run_uca cursor
  assert_no_warning

  new_case cursor-agent-alias
  rm "${ACTIVE}/cursor-agent" "${ACTIVE}/agent"
  make_probe "${CASE_HOME}/.local/share/cursor-agent/versions/old/cursor-agent" 2026.09.10-ffffff
  ln -s "${CASE_HOME}/.local/share/cursor-agent/versions/old/cursor-agent" "${ACTIVE}/agent"
  make_probe "${CASE_HOME}/.local/share/cursor-agent/versions/new/cursor-agent" 2026.09.11-000000
  ln -s "${CASE_HOME}/.local/share/cursor-agent/versions/new/cursor-agent" "${SHADOW}/agent"
  run_uca cursor
  assert_warning "${ACTIVE}/agent" "${SHADOW}/agent" 2026.09.10-ffffff 2026.09.11-000000

  new_case foreign-agent
  make_probe "${ACTIVE}/cursor-agent" 2026.09.10-ffffff
  make_probe "${SHADOW}/agent" 2099.01.01-ffffff
  run_uca cursor
  if grep -Fq "${SHADOW}/agent|" "${CALLS}"; then fail 'unrelated agent was executed'; fi
  assert_no_warning

  new_case omp
  make_probe "${ACTIVE}/omp" 1.0.0
  make_probe "${SHADOW}/omp" 2.0.0
  run_uca omp
  assert_warning "${ACTIVE}/omp" "${SHADOW}/omp" 1.0.0 2.0.0

  if grep -q '^check_only_harness()' "${SUBJECT}"; then
    new_case rtk
    make_probe "${ACTIVE}/rtk" 1.0.0
    make_probe "${SHADOW}/rtk" 2.0.0
    run_uca rtk
    assert_warning "${ACTIVE}/rtk" "${SHADOW}/rtk" 1.0.0 2.0.0
  else
    printf 'SKIP: RTK is not supported by this subject\n'
  fi
  printf 'PASS: %s shadowed-install cases\n' "${CASES}"
}

main "$@"
