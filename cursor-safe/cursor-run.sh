#!/usr/bin/env bash
# cursor-run.sh — Resume, don't restart: a wrapper for the Cursor CLI
# (`cursor-agent`) that survives host reboots / VM replacements.
#
# What it does:
# - Prints host boot age and a rough interruption-risk label before starting
# - Persists prompt / repo / branch / HEAD / boot_id under
#   $CURSOR_RUNS_DIR/<run_id>/ (on persistent storage, so it survives a reboot)
# - Every 60s (configurable), atomically snapshots git status / diff /
#   copies of changed files into checkpoint/
# - Keeps a decision log, PROGRESS.md, in the run dir: the agent appends
#   what it did, decisions and why, approaches tried and discarded and why,
#   and the next step, before each milestone commit. --resume embeds the
#   full log into the resume prompt, and a resumed run inherits the file.
#   (Raw chain-of-thought cannot be saved; this is its distilled form.)
# - Marks the run complete / failed at exit. A run still marked "running"
#   whose boot_id changed or whose PID is gone is detected as interrupted
#   by cursor-check.sh.
# - --resume <run_id> generates a resume prompt joining the original
#   prompt, the checkpoint, and the current git state (it does not start
#   a new run by itself). Resume prompts forbid `git push`: a resumed run
#   stops at commits.
#
# Usage:
#   cursor-run.sh --repo DIR --prompt FILE [--model MODEL] [--slug NAME]
#              [--timeout-min N] [--checkpoint-sec N]
#   cursor-run.sh --resume RUN_ID
#   DRY_RUN_CMD='...' cursor-run.sh ...   # testing: run any command instead of cursor-agent
#
# Environment:
#   CURSOR_RUNS_DIR     run storage (default: $HOME/cursor-runs)
#   CURSOR_MODEL        default model (default: composer-2.5)
#   CURSOR_RISK_MED_MIN boot age (min) where risk becomes "medium" (default: 60)
#   CURSOR_RISK_HIGH_MIN boot age (min) where risk becomes "HIGH" (default: 90)
#
# Requirements: Linux, bash, git, GNU coreutils (date -d, uptime -s),
# and `cursor-agent` on PATH (or $HOME/.local/bin).
set -u
RUNS_DIR="${CURSOR_RUNS_DIR:-$HOME/cursor-runs}"
MODEL="${CURSOR_MODEL:-composer-2.5}"
RISK_MED_MIN="${CURSOR_RISK_MED_MIN:-60}"
RISK_HIGH_MIN="${CURSOR_RISK_HIGH_MIN:-90}"
TIMEOUT_MIN=55
CHECKPOINT_SEC=60
REPO="" PROMPT="" SLUG="task" RESUME_ID="" RESUME_OF=""

while [ $# -gt 0 ]; do
case "$1" in
--repo) REPO="$2"; shift 2;;
--prompt) PROMPT="$2"; shift 2;;
--model) MODEL="$2"; shift 2;;
--slug) SLUG="$2"; shift 2;;
--timeout-min) TIMEOUT_MIN="$2"; shift 2;;
--checkpoint-sec) CHECKPOINT_SEC="$2"; shift 2;;
--resume) RESUME_ID="$2"; shift 2;;
    --resume-of) RESUME_OF="$2"; shift 2;;
*) echo "unknown arg: $1" >&2; exit 2;;
esac
done

boot_id() { cat /proc/sys/kernel/random/boot_id 2>/dev/null;}
boot_age_min() {
local s; s=$(uptime -s 2>/dev/null) || { echo -1; return;}
echo $(( ( $(date +%s) - $(date -d "$s" +%s)) / 60))
}
risk_of() { # age_min -> label. Thresholds are a heuristic: if your host
# reboots on a known cadence, tune CURSOR_RISK_* to match it.
local a=$1
if [ "$a" -lt 0 ]; then echo "unknown"
elif [ "$a" -lt "$RISK_MED_MIN" ]; then echo "low"
elif [ "$a" -lt "$RISK_HIGH_MIN" ]; then echo "medium"
else echo "HIGH (consider splitting the task into shorter milestones or shortening the checkpoint interval)"; fi
}

snapshot() { # $1=repo $2=dest_dir
local repo="$1" dest="$2" f
mkdir -p "$dest/files"
git -C "$repo" status --porcelain=v1 > "$dest/status.txt.tmp" 2>/dev/null || true
git -C "$repo" diff HEAD > "$dest/diff.patch.tmp" 2>/dev/null || true
git -C "$repo" diff --stat HEAD > "$dest/diffstat.txt.tmp" 2>/dev/null || true
git -C "$repo" log --oneline -5 > "$dest/log.txt.tmp" 2>/dev/null || true
# Copy the actual changed/untracked files (via a tmp dir, so a partial
# write never destroys the previous generation)
rm -rf "$dest/files.tmp"; mkdir -p "$dest/files.tmp"
git -C "$repo" ls-files -m -o --exclude-standard 2>/dev/null | while IFS= read -r f; do
[ -f "$repo/$f" ] || continue
mkdir -p "$dest/files.tmp/$(dirname "$f")"
cp -a "$repo/$f" "$dest/files.tmp/$f" 2>/dev/null || true
done
for x in status.txt diff.patch diffstat.txt log.txt; do
[ -f "$dest/$x.tmp" ] && mv "$dest/$x.tmp" "$dest/$x"
done
rm -rf "$dest/files.old"; [ -d "$dest/files" ] && mv "$dest/files" "$dest/files.old"
mv "$dest/files.tmp" "$dest/files"; rm -rf "$dest/files.old"
# Generation copy of the decision log (the live file is in the run dir)
if [ -f "$(dirname "$dest")/PROGRESS.md" ]; then
cp -a "$(dirname "$dest")/PROGRESS.md" "$dest/progress.md.tmp" 2>/dev/null && mv "$dest/progress.md.tmp" "$dest/progress.md" || true
fi
date '+%Y-%m-%dT%H:%M:%S%z' > "$dest/at.txt"
}

# ---------- resume prompt generation ----------
if [ -n "$RESUME_ID" ]; then
OLD="$RUNS_DIR/$RESUME_ID"
[ -d "$OLD" ] || { echo "run not found: $OLD" >&2; exit 1;}
. "$OLD/manifest.env"
chain_id=${chain_id:-$RESUME_ID}
auto_resume_count=${auto_resume_count:-0}
next_count=$((auto_resume_count + 1))
printf "chain_id=%s\nauto_resume_count=%s\nparent_run=%s\n" "$chain_id" "$next_count" "$RESUME_ID" > "$OLD/RESUME-meta.env"
OUT="$OLD/RESUME-prompt.txt"
{
echo "This is a continuation of a Cursor run that was interrupted (host reboot / process kill). Do not start over."
echo ""
echo "TOP RULE: Never run git push in this resumed run. Even if the original request asked for a push, that instruction is void here. Stop at commits."
echo ""
echo "## Interrupted run"
echo "- run_id: $RESUME_ID / repo: $repo / branch at start: $branch / HEAD at start: $head"
echo "- started: $started_at / boot_id at start: $boot_id_start (current: $(boot_id))"
echo "- checkpoint: $OLD/checkpoint/ (status.txt / diff.patch / diffstat.txt / files/ hold the last saved state)"
echo ""
echo "## Do this first"
echo "1. In the repo, check git status / git diff HEAD / git log --oneline -10"
echo "2. Read the decision log (PROGRESS.md) below. Do not retry a discarded approach while the reason it was discarded still holds"
echo "3. Compare with the checkpoint diffstat; do not redo milestones that are already done"
echo "4. Treat uncommitted changes as your predecessor's work: inherit them and fix only what is broken"
echo "5. Commit in milestones (implementation -> tests -> docs)"
echo ""
echo "## checkpoint diffstat"
cat "$OLD/checkpoint/diffstat.txt" 2>/dev/null || echo "(none)"
echo ""
echo "## Decision log (full PROGRESS.md)"
cat "$OLD/PROGRESS.md" 2>/dev/null || echo "(no decision log — legacy run)"
echo ""
echo "## Original request (full)"
cat "$OLD/prompt.txt"
} > "$OUT"
echo "resume prompt: $OUT"
echo "next: cursor-run.sh --repo \"$repo\" --prompt \"$OUT\" --slug \"${slug}-resume\" --resume-of \"$RESUME_ID\""
exit 0
fi

# ---------- normal run ----------
[ -n "$REPO" ] && [ -n "$PROMPT" ] || { echo "usage: --repo DIR --prompt FILE" >&2; exit 2;}
[ -d "$REPO/.git" ] || { echo "not a git repo: $REPO" >&2; exit 2;}
[ -f "$PROMPT" ] || { echo "prompt not found: $PROMPT" >&2; exit 2;}

AGE=$(boot_age_min); echo "boot age: ${AGE} min / risk: $(risk_of "$AGE")"
RUN_ID="$(date '+%Y%m%d-%H%M%S')-$(echo "$SLUG" | tr -cd 'a-zA-Z0-9-')"
RUN_DIR="$RUNS_DIR/$RUN_ID"; mkdir -p "$RUN_DIR/checkpoint"
cp "$PROMPT" "$RUN_DIR/prompt.txt"
{
echo ""
echo "---"
echo "[checkpoint rule] Commit in milestones (implementation -> tests -> docs)."
echo "This run may be killed by a host reboot, but the working files and checkpoints"
echo "remain in $RUN_DIR and the work can be resumed from there. Proceed on that assumption."
echo ""
echo "[decision log rule] Maintain the decision log at $RUN_DIR/PROGRESS.md."
echo "- Append one entry BEFORE each milestone commit, and whenever you make an important decision, discard an approach you tried, or get stuck"
echo "- Format: under a '### YYYY-MM-DD HH:MM <title>' heading, write: what you did / decision and reason / approaches tried and discarded and why (write 'none' if none) / next step / open issues and cautions"
echo "- Append only. Never rewrite past entries (to reverse a decision, add a new entry stating that it supersedes the earlier one). Never write secrets such as passwords or tokens"
echo "- If this is a resumed run, PROGRESS.md already contains your predecessors' entries. Read it before starting, and do not retry discarded approaches without a reason"
} >> "$RUN_DIR/prompt.txt"

BRANCH=$(git -C "$REPO" branch --show-current 2>/dev/null)
HEAD=$(git -C "$REPO" rev-parse --short HEAD 2>/dev/null)
CHAIN_ID=$RUN_ID; AUTO_COUNT=0; PARENT_RUN=
if [ -n "$RESUME_OF" ] && [ -f "$RUNS_DIR/$RESUME_OF/RESUME-meta.env" ]; then
  . "$RUNS_DIR/$RESUME_OF/RESUME-meta.env"
  CHAIN_ID=$chain_id; AUTO_COUNT=$auto_resume_count; PARENT_RUN=$parent_run
fi
cat > "$RUN_DIR/manifest.env" <<EOF
agent=cursor
repo=$REPO
branch=$BRANCH
head=$HEAD
slug=$SLUG
model=$MODEL
boot_id_start=$(boot_id)
started_at=$(date '+%Y-%m-%dT%H:%M:%S%z')
boot_age_min_at_start=$AGE
chain_id=$CHAIN_ID
auto_resume_count=$AUTO_COUNT
parent_run=$PARENT_RUN
EOF
# ---------- decision log (PROGRESS.md): inherit or create ----------
if [ -n "$RESUME_OF" ] && [ -f "$RUNS_DIR/$RESUME_OF/PROGRESS.md" ]; then
cp -a "$RUNS_DIR/$RESUME_OF/PROGRESS.md" "$RUN_DIR/PROGRESS.md"
{
echo ""
echo "---"
echo "## Resumed $(date '+%Y-%m-%dT%H:%M:%S%z') — run $RUN_ID (inherits the decision log of run $RESUME_OF)"
} >> "$RUN_DIR/PROGRESS.md"
else
cat > "$RUN_DIR/PROGRESS.md" <<PROGRESS_EOF
# Decision log (PROGRESS) — $SLUG
- run_id: $RUN_ID / started: $(date '+%Y-%m-%dT%H:%M:%S%z')
- repo: $REPO / branch: $BRANCH / HEAD at start: $HEAD / model: $MODEL
- Purpose: a distilled log from which a successor run can reconstruct what was decided and why, and what was tried and discarded. (Raw chain-of-thought cannot be saved.)
- Rules: append only (never rewrite past entries). Never write secrets.

## Entries
PROGRESS_EOF
fi

echo running > "$RUN_DIR/status.txt"
snapshot "$REPO" "$RUN_DIR/checkpoint"

PROMPT_TEXT=$(cat "$RUN_DIR/prompt.txt")
if [ -n "${DRY_RUN_CMD:-}" ]; then
( cd "$REPO" && timeout "${TIMEOUT_MIN}m" bash -c "$DRY_RUN_CMD") > "$RUN_DIR/output.log" 2>&1 &
else
export PATH="$HOME/.local/bin:$PATH"
( cd "$REPO" && timeout "${TIMEOUT_MIN}m" cursor-agent -p --add-dir "$RUN_DIR" --model "$MODEL" --force "$PROMPT_TEXT" < /dev/null) > "$RUN_DIR/output.log" 2>&1 &
fi
CHILD=$!
echo "$CHILD" > "$RUN_DIR/pid.txt"
echo "run_id=$RUN_ID pid=$CHILD dir=$RUN_DIR"

( while kill -0 "$CHILD" 2>/dev/null; do sleep "$CHECKPOINT_SEC"; snapshot "$REPO" "$RUN_DIR/checkpoint"; done) &
WATCHER=$!
wait "$CHILD"; CODE=$?
kill "$WATCHER" 2>/dev/null || true
snapshot "$REPO" "$RUN_DIR/checkpoint"
if [ "$CODE" -eq 0 ]; then echo complete > "$RUN_DIR/status.txt"; else echo failed > "$RUN_DIR/status.txt"; fi
echo "exit_code=$CODE" >> "$RUN_DIR/manifest.env"
echo "ended_at=$(date '+%Y-%m-%dT%H:%M:%S%z')" >> "$RUN_DIR/manifest.env"
echo "run $RUN_ID finished: status=$(cat "$RUN_DIR/status.txt") exit=$CODE"
exit "$CODE"
