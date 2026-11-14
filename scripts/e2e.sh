#!/usr/bin/env bash
# End-to-end test: drives the real `container` runtime through Titan using examples/todo-api.
# Usage: scripts/e2e.sh            (KEEP=1 to leave the VM running afterwards)
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PROJECT="$ROOT/examples/todo-api"
TITAN="${TITAN:-$ROOT/.build/release/titan}"
PORT=3000
pass=0 fail=0

green() { printf '\033[32m%s\033[0m\n' "$*"; }
red()   { printf '\033[31m%s\033[0m\n' "$*"; }
check() {  # check "<description>" <command...>
  local desc="$1"; shift
  if "$@" >/tmp/titan-e2e.out 2>&1; then green "✓ $desc"; pass=$((pass+1))
  else red "✗ $desc"; sed 's/^/    /' /tmp/titan-e2e.out | tail -15; fail=$((fail+1)); fi
}
titan() { "$TITAN" -C "$PROJECT" "$@"; }

[ -x "$TITAN" ] || (cd "$ROOT" && swift build -c release >/dev/null) || exit 1
command -v container >/dev/null || { red "container CLI not installed"; exit 1; }
cd "$PROJECT"

echo "== titan e2e ($("$TITAN" --version), $(container --version))"
check "doctor passes"                    titan doctor
check "up creates the VM"                titan up
check "second up is a fast no-op"        bash -c "s=\$(date +%s); '$TITAN' -C '$PROJECT' up && [ \$((\$(date +%s)-s)) -le 2 ]"
check "titan.lock pins a digest"         grep -q '"digest" : "sha256:' titan.lock
check "tests pass inside the VM"         titan run -- npm test
check "runs on Linux"                    bash -c "'$TITAN' -C '$PROJECT' run -- uname -s | grep -qx Linux"
check "native module built for Linux"    bash -c "file node_modules/better-sqlite3/build/Release/better_sqlite3.node | grep -q ELF"
check "cwd maps into the VM"             bash -c "cd src && '$TITAN' run -- pwd | grep -qx /workspaces/todo-api/src"
check "exit codes pass through"          bash -c "'$TITAN' -C '$PROJECT' run -- sh -c 'exit 7'; [ \$? -eq 7 ]"
check "stdin passes through"             bash -c "echo hi | '$TITAN' -C '$PROJECT' run -- cat | grep -qx hi"
check "remoteEnv is applied"             bash -c "'$TITAN' -C '$PROJECT' run -- printenv APP_ENV | grep -qx development"

titan run -- npm start >/dev/null 2>&1 &
for _ in $(seq 1 20); do curl -sf "localhost:$PORT/health" >/dev/null && break; sleep 0.5; done
check "port $PORT is forwarded"          bash -c "curl -sf localhost:$PORT/health | grep -q '\"platform\":\"Linux arm64\"'"
check "API round-trip"                   bash -c "curl -sf -X POST localhost:$PORT/todos -H 'content-type: application/json' -d '{\"title\":\"e2e\"}' | grep -q '\"title\":\"e2e\"'"
titan run -- sh -c 'pkill -f src/server.js' >/dev/null 2>&1

check "down stops the VM"                bash -c "'$TITAN' -C '$PROJECT' down && '$TITAN' -C '$PROJECT' status | grep -q stopped"
check "up restarts it"                   bash -c "'$TITAN' -C '$PROJECT' up && '$TITAN' -C '$PROJECT' run -- true"
[ "${KEEP:-0}" = 1 ] || check "down --rm deletes the VM" titan down --rm

echo; [ $fail -eq 0 ] && green "All $pass checks passed" || red "$fail failed, $pass passed"
exit $(( fail > 0 ))
