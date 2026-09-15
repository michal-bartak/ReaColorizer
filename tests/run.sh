#!/usr/bin/env bash
#
# Run the whole suite. Needs a standalone Lua (brew install lua) and python3.
#
#   ./tests/run.sh
#
# Nothing here touches REAPER or your rule file: the REAPER API is mocked and
# every test writes under tests/.tmp.

set -uo pipefail

TESTS="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export NC="$(dirname "$TESTS")"
export SP="$TESTS/.tmp"

mkdir -p "$SP/cfgtest"
rc=0

# Capture first, print after. Piping straight into `tail` would report tail's
# exit status, which is always 0 -- so every failure would look green.
run() {
  local out st
  out="$("$@" 2>&1)"; st=$?
  printf '%s\n' "$out" | tail -n 3
  [ $st -eq 0 ] || rc=1
}

echo "== unit (regex, matcher, colours, config, apply) =="
( cd "$NC" && NC_TEST_DIR="$SP/cfgtest" lua MB_NameColorizer_RunTests.lua ) >"$SP/unit.out" 2>&1
[ $? -eq 0 ] || rc=1
tail -n 3 "$SP/unit.out"

for t in integration autoloop gui render; do
  echo "== $t =="
  run lua "$TESTS/$t.lua"
done

echo "== differential fuzz vs python re =="
for seed in 12345 777 2024; do
  python3 "$TESTS/fuzz_gen.py" "$seed" >/dev/null || rc=1
  run lua "$TESTS/fuzz_run.lua"
done

echo
if [ $rc -eq 0 ]; then echo "ALL GREEN"; else echo "FAILURES -- see above"; fi
exit $rc
