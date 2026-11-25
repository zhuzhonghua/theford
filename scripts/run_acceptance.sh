#!/usr/bin/env bash
# Batch acceptance runner. Each script runs in its own headless Godot process
# (scripts intentionally leave state behind), but several run concurrently so
# cold start / model loading is paid in parallel rather than 20 times in a row.
#
#   scripts/run_acceptance.sh            # all scripts, 4 jobs
#   JOBS=8 scripts/run_acceptance.sh      # more parallel processes
#   scripts/run_acceptance.sh quests save # just these two
#
# Exit status is non-zero if any script failed.

set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
GODOT="${GODOT:-/Applications/Godot.app/Contents/MacOS/Godot}"
JOBS="${JOBS:-4}"
QUALITY="${THEFORD_AI_QUALITY:-off}"
LOGDIR="$(mktemp -d "${TMPDIR:-/tmp}/theford-acceptance.XXXXXX")"

ALL_SCRIPTS=(
  audio bag-pickup combat container-panel container-persist equipment
  fell-tree flee game-over inventory-panel portal prompt quality quests
  read-sign reload-scene save volume story story-chain ui-panels
)

if [ "$#" -gt 0 ]; then
  SCRIPTS=("$@")
else
  SCRIPTS=("${ALL_SCRIPTS[@]}")
fi

run_one() {
  local name="$1"
  THEFORD_AI_QUALITY="$QUALITY" THEFORD_ACCEPTANCE="$name" THEFORD_ACCEPTANCE_QUIT=1 \
    "$GODOT" --headless --path "$ROOT" scenes/main.tscn > "$LOGDIR/$name.log" 2>&1
  local result
  result="$(grep -E '\[acceptance\] (OK|FAIL)' "$LOGDIR/$name.log" | tail -1)"
  printf '%-18s %s\n' "$name" "${result:-NO RESULT}"
  if printf '%s' "$result" | grep -q 'OK:'; then
    printf 'ok\n' > "$LOGDIR/$name.status"
  else
    printf 'fail\n' > "$LOGDIR/$name.status"
  fi
}

export ROOT GODOT QUALITY LOGDIR
export -f run_one

printf '%s\n' "${SCRIPTS[@]}" | xargs -P "$JOBS" -I{} bash -c 'run_one "$@"' _ {} |

while IFS= read -r line; do printf '%s\n' "$line"; done

failed=0
for name in "${SCRIPTS[@]}"; do
  if [ "$(cat "$LOGDIR/$name.status" 2>/dev/null)" != "ok" ]; then
    failed=$((failed + 1))
    printf '\n--- %s failed ---\n' "$name"
    tail -25 "$LOGDIR/$name.log"
  fi
done

printf '\n%d/%d passed, logs in %s\n' "$(( ${#SCRIPTS[@]} - failed ))" "${#SCRIPTS[@]}" "$LOGDIR"
[ "$failed" -eq 0 ]
