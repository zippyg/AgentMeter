#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
if [[ $# -gt 1 ]]; then
  echo "ERROR: Usage: $0 [binary-or-app-bundle]" >&2
  exit 1
fi

PROFILE_TARGET="${1:-${AGENTMETER_PROFILE_BINARY:-${ROOT_DIR}/.build/release/AgentMeter}}"
if [[ -d "${PROFILE_TARGET}" && "${PROFILE_TARGET}" == *.app ]]; then
  plist="${PROFILE_TARGET}/Contents/Info.plist"
  executable="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "${plist}" 2>/dev/null || true)"
  if [[ -z "${executable}" ]]; then
    echo "ERROR: Could not read CFBundleExecutable from ${plist}" >&2
    exit 1
  fi
  BINARY="${PROFILE_TARGET}/Contents/MacOS/${executable}"
  PROFILE_LABEL="${AGENTMETER_PROFILE_LABEL:-$(basename "${PROFILE_TARGET}" .app)}"
else
  BINARY="${PROFILE_TARGET}"
  PROFILE_LABEL="${AGENTMETER_PROFILE_LABEL:-$(basename "${BINARY}")}"
fi
ARTIFACT_DIR="${ROOT_DIR}/.agentmeter-artifacts/perf"
WARMUP_SECONDS="${AGENTMETER_PROFILE_WARMUP_SECONDS:-12}"
SAFE_LABEL="$(printf "%s" "${PROFILE_LABEL}" | tr -c 'A-Za-z0-9._-' '-')"

if [[ ! -x "${BINARY}" ]]; then
  echo "ERROR: release binary missing at ${BINARY}. Run: swift build -c release --product AgentMeter" >&2
  exit 1
fi

existing_pids="$(
  ps -axo pid=,comm= | awk -v binary="${BINARY}" '$2 == binary { print $1 }'
)"
if [[ -n "${existing_pids}" ]]; then
  echo "ERROR: ${BINARY} is already running. Refusing to stop user-owned processes: ${existing_pids}" >&2
  exit 1
fi

mkdir -p "${ARTIFACT_DIR}"
stamp="$(date -u +"%Y%m%d-%H%M%SZ")"
report="${ARTIFACT_DIR}/agentmeter-safe-launch-profile-${SAFE_LABEL}-${stamp}.md"
launch_log="${ARTIFACT_DIR}/agentmeter-safe-launch-profile-${SAFE_LABEL}-${stamp}.log"

AGENTMETER_SAFE_LAUNCH=1 \
AGENTMETER_DISABLE_PROVIDER_PROBES=1 \
AGENTMETER_DISABLE_SECRET_MIGRATION=1 \
"${BINARY}" >"${launch_log}" 2>&1 &
pid="$!"

cleanup() {
  if kill -0 "${pid}" 2>/dev/null; then
    kill "${pid}" 2>/dev/null || true
    wait "${pid}" 2>/dev/null || true
  fi
}
trap cleanup EXIT

sleep "${WARMUP_SECONDS}"

if ! kill -0 "${pid}" 2>/dev/null; then
  echo "ERROR: ${PROFILE_LABEL} exited before profiling completed. Launch log: ${launch_log}" >&2
  exit 1
fi

ps_line="$(ps -p "${pid}" -o pid=,ppid=,etime=,%cpu=,rss=,vsz=,stat=,comm=)"
rss_kb="$(ps -p "${pid}" -o rss= | tr -d '[:space:]')"
cpu_percent="$(ps -p "${pid}" -o %cpu= | tr -d '[:space:]')"
rss_mb="$(awk "BEGIN { printf \"%.1f\", ${rss_kb:-0} / 1024 }")"
children="$(pgrep -P "${pid}" || true)"
children_csv="$(printf "%s" "${children}" | tr '\n' ',' | sed 's/,$//')"
network="$(lsof -nP -a -p "${pid}" -iTCP -iUDP 2>/dev/null || true)"
socket_count="0"
if [[ -n "${network}" ]]; then
  socket_count="$(printf "%s\n" "${network}" | tail -n +2 | sed '/^[[:space:]]*$/d' | wc -l | tr -d '[:space:]')"
fi

{
  echo "# AgentMeter Safe Launch Profile"
  echo
  echo "Date UTC: ${stamp}"
  echo
  echo "## Launch"
  echo
  echo "- Binary: \`${BINARY}\`"
  echo "- Label: \`${PROFILE_LABEL}\`"
  echo "- PID: \`${pid}\`"
  echo "- Warmup seconds: \`${WARMUP_SECONDS}\`"
  echo "- Safe env: \`AGENTMETER_SAFE_LAUNCH=1 AGENTMETER_DISABLE_PROVIDER_PROBES=1 AGENTMETER_DISABLE_SECRET_MIGRATION=1\`"
  echo
  echo "## Process Sample"
  echo
  echo "\`\`\`text"
  echo "PID PPID ELAPSED CPU RSS_KB VSZ_KB STAT COMMAND"
  echo "${ps_line}"
  echo "\`\`\`"
  echo
  echo "- RSS MB: \`${rss_mb}\`"
  echo "- CPU percent sample: \`${cpu_percent:-0}\`"
  echo
  echo "## Child Processes"
  echo
  if [[ -n "${children}" ]]; then
    echo "\`\`\`text"
    ps -p "${children_csv}" -o pid=,ppid=,etime=,%cpu=,rss=,comm=
    echo "\`\`\`"
  else
    echo "No child processes."
  fi
  echo
  echo "## Network Sockets"
  echo
  echo "- Socket count: \`${socket_count}\`"
  if [[ -n "${network}" ]]; then
    echo
    echo "\`\`\`text"
    echo "${network}"
    echo "\`\`\`"
  else
    echo
    echo "No TCP/UDP sockets reported for the AgentMeter process."
  fi
  echo
  echo "## Launch Log"
  echo
  echo "- Log path: \`${launch_log}\`"
  if [[ -s "${launch_log}" ]]; then
    echo
    echo "\`\`\`text"
    tail -n 80 "${launch_log}"
    echo "\`\`\`"
  else
    echo
    echo "Launch log was empty."
  fi
} >"${report}"

echo "${report}"
