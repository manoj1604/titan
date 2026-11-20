#!/usr/bin/env bash
# Multi-language end-to-end test: zero-config detection, install, tests, run, port forwarding.
# Usage: scripts/e2e-langs.sh [project...]    (default: all)
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TITAN="${TITAN:-$ROOT/.build/release/titan}"
LOG="${TMPDIR:-/tmp}/titan-e2e-langs"
mkdir -p "$LOG"
pass=0 fail=0

# name | test command | run command | port ("" = CLI: check run output instead) | expected in output
PROJECTS=(
  "python-api|python -m pytest -q|python app.py|8000|Linux aarch64"
  "go-api|go test ./...|go run .|8080|linux arm64"
  "rust-cli|cargo test -q|cargo run -q||linux aarch64"
  "ruby-app|bundle exec ruby -Itest test/app_test.rb|bundle exec rackup -o 0.0.0.0 -p 3000|3000|linux aarch64"
  "java-maven|mvn -q test|java -cp target/classes dev.titan.demo.App||Linux aarch64"
)

green() { printf '\033[32m%s\033[0m\n' "$*"; }
red()   { printf '\033[31m%s\033[0m\n' "$*"; }
check() {
  local desc="$1"; shift
  local start=$SECONDS
  if "$@" >"$LOG/last.out" 2>&1; then green "  ✓ $desc ($((SECONDS-start))s)"; pass=$((pass+1))
  else red "  ✗ $desc ($((SECONDS-start))s)"; sed 's/^/      /' "$LOG/last.out" | tail -20; fail=$((fail+1)); fi
}

[ -x "$TITAN" ] || (cd "$ROOT" && swift build -c release >/dev/null) || exit 1
selected=("$@")

for spec in "${PROJECTS[@]}"; do
  IFS='|' read -r name test_cmd run_cmd port expect <<<"$spec"
  if [ ${#selected[@]} -gt 0 ] && [[ ! " ${selected[*]} " =~ " $name " ]]; then continue; fi
  dir="$ROOT/examples/$name"
  t() { "$TITAN" -C "$dir" "$@"; }
  echo "== $name ($(t status | sed -n 's/^config *//p'))"

  check "up (detect + pull + install)"  t up
  check "tests pass in VM: $test_cmd"   t run -- sh -c "$test_cmd"
  check "runs on Linux"                 bash -c "'$TITAN' -C '$dir' run -- uname -s | grep -qx Linux"
  if [ -n "$port" ]; then
    # Titan remaps a port that's busy on the Mac; find where the app's port really landed
    # (`titan status` prints e.g. "ports     3001→3000, 5000").
    host=$(t status | sed -n 's/^ports *//p' | tr ',' '\n' | tr -d ' ' | awk -F'→' -v p="$port" '($2==p)||($1==p && $2==""){print $1; exit}')
    host=${host:-$port}
    t run -- sh -c "$run_cmd" >"$LOG/$name-server.log" 2>&1 &
    check "serves http://localhost:$host/health" bash -c "
      for i in \$(seq 1 120); do out=\$(curl -sf localhost:$host/health) && break; sleep 1; done
      echo \"\$out\"; echo \"\$out\" | grep -q '$expect'"
  else
    check "runs: $run_cmd" bash -c "'$TITAN' -C '$dir' run -- sh -c '$run_cmd' | tee /dev/stderr | grep -q '$expect'"
  fi
  [ "${KEEP:-0}" = 1 ] || check "down --rm" t down --rm
done

echo; [ $fail -eq 0 ] && green "All $pass checks passed" || red "$fail failed, $pass passed"
exit $(( fail > 0 ))
