#!/usr/bin/env bash
# agy-check.sh — Show boot age / risk, and detect interrupted agy runs.
#   A run counts as interrupted when it is still marked "running" and
#   (a) its boot_id differs from the current boot, or
#   (b) its recorded PID no longer exists.
# With --mark, matching runs are re-marked as "interrupted".
set -u
RUNS_DIR="${AGY_RUNS_DIR:-$HOME/agy-runs}"
RISK_MED_MIN="${AGY_RISK_MED_MIN:-60}"
RISK_HIGH_MIN="${AGY_RISK_HIGH_MIN:-90}"
MARK=0; [ "${1:-}" = "--mark" ] && MARK=1
AGE_MIN=$(( ( $(date +%s) - $(date -d "$(uptime -s)" +%s) ) / 60 ))
echo "boot: $(uptime -s) (${AGE_MIN} min ago) boot_id=$(cat /proc/sys/kernel/random/boot_id)"
if [ "$AGE_MIN" -lt "$RISK_MED_MIN" ]; then echo "risk: low"
elif [ "$AGE_MIN" -lt "$RISK_HIGH_MIN" ]; then echo "risk: medium"
else echo "risk: HIGH"; fi
echo "---"
FOUND=0
for d in "$RUNS_DIR"/*/; do
  [ -f "$d/status.txt" ] || continue
  [ "$(cat "$d/status.txt")" = "running" ] || continue
  . "$d/manifest.env"
  PID=$(cat "$d/pid.txt" 2>/dev/null || echo "")
  WHY=""
  [ "$boot_id_start" != "$(cat /proc/sys/kernel/random/boot_id)" ] && WHY="boot changed"
  if [ -n "$PID" ] && ! kill -0 "$PID" 2>/dev/null; then WHY="${WHY:+$WHY, }pid $PID gone"; fi
  [ -n "$WHY" ] || continue
  FOUND=1
  echo "INTERRUPTED: $(basename "$d")"
  echo "  repo=$repo slug=$slug started=$started_at why: $WHY"
  echo "  checkpoint: $(cat "$d/checkpoint/at.txt" 2>/dev/null) / diff: $(wc -l < "$d/checkpoint/diff.patch" 2>/dev/null || echo 0) lines"
  echo "  resume: agy-run.sh --resume $(basename "$d")"
  [ "$MARK" -eq 1 ] && echo interrupted > "$d/status.txt"
done
[ "$FOUND" -eq 0 ] && echo "interrupted runs: none"
exit 0
