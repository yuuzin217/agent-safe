# agent-safe

**Resume, don't restart.** Bash wrappers that let long-running CLI coding
agents survive a host reboot, a VM replacement, or a killed process —
and pick up *where they left off* instead of starting over.

Two wrappers, one design:

| Wrapper | Agent CLI | Run storage (default) |
|---|---|---|
| [`agy-safe/`](agy-safe/) | Antigravity CLI (`agy`) | `$HOME/agy-runs/` |
| [`cursor-safe/`](cursor-safe/) | Cursor CLI (`cursor-agent`) | `$HOME/cursor-runs/` |

日本語版: [README.ja.md](README.ja.md)

## The problem

Run a coding agent for 30–60 minutes on an ephemeral VM (cloud dev
environments, CI runners, replaceable sandboxes) and the host may reboot
or be replaced mid-task. The reboot itself is not the real damage — the
damage is losing *what was done, what was decided, and what was already
tried*, so the next run starts from zero and repeats discarded work.

## What the wrappers do

1. **Persist the run before it starts** — prompt, repo, branch, HEAD and
   `boot_id` are saved to a run directory on persistent storage.
2. **Checkpoint every 60 seconds** — git status, full diff, diffstat and
   copies of the changed files are snapshotted atomically (via tmp files,
   so a partial write never destroys the previous generation). At most
   you lose the last checkpoint interval of uncommitted work. These are
   *snapshots*, not git commits — your history stays clean; the agent
   itself commits at milestones.
3. **Decision log (`PROGRESS.md`)** — raw chain-of-thought cannot be
   saved, so the wrapper instructs the agent to append a distilled entry
   before each milestone commit: what was done, decisions and reasons,
   approaches tried and discarded (and why), next step, open issues.
   Append-only; a run that resumes inherits the whole log.
4. **Detect interruptions** — `*-check.sh` finds runs still marked
   `running` whose boot changed or whose PID is gone.
5. **Generate a resume prompt** — `--resume RUN_ID` joins the original
   prompt, the checkpoint diffstat and the full decision log into a
   resume prompt that tells the successor: don't start over, don't retry
   discarded approaches, inherit uncommitted work — and **never
   `git push` in a resumed run** (a resumed run stops at commits; pushing
   stays a separate, explicit decision).

The wrappers deliberately do **not** auto-resume anything. Detection and
resume-prompt generation are as far as they go; wiring them to a cron
job, a file watcher, or a human is up to you.

## Quick start

```bash
# 1. Check boot age / interruption risk and any interrupted runs
agy-safe/agy-check.sh

# 2. Run a task (prompt is a file)
agy-safe/agy-run.sh --repo /path/to/repo --prompt task.md --slug my-task

# 3. If the host rebooted mid-run:
agy-safe/agy-check.sh --mark          # mark interrupted runs
agy-safe/agy-run.sh --resume 20261113-101500-my-task
# -> writes RESUME-prompt.txt and prints the exact command to start
#    the resumed run with it
```

`cursor-safe/` works identically with `cursor-run.sh` / `cursor-check.sh`.

### Options & environment

```
--model MODEL          agent model (agy default: claude-sonnet-5-5-medium,
                       cursor default: composer-2.5; or set AGY_MODEL /
                       CURSOR_MODEL)
--timeout-min N        run timeout (default: 55)
--checkpoint-sec N     checkpoint interval (default: 60)
AGY_RUNS_DIR / CURSOR_RUNS_DIR     run storage location
AGY_RISK_MED_MIN / AGY_RISK_HIGH_MIN (and CURSOR_ equivalents)
                       boot-age thresholds for the risk label. These are
                       a heuristic — if your host reboots on a known
                       cadence, tune them to it.
DRY_RUN_CMD='...'      testing hook: run any command instead of the agent
```

## Requirements

- Linux (uses `/proc/sys/kernel/random/boot_id`, `uptime -s`, GNU
  `date -d`) — macOS is not supported as-is
- bash, git, GNU coreutils
- `agy` and/or `cursor-agent` installed and authenticated

## Safety notes

- The wrappers invoke the agents in their unattended modes
  (`agy --dangerously-skip-permissions`, `cursor-agent --force`). Only
  run them on repositories and machines where you accept that. Review
  the two invocation lines (one per `*-run.sh`) before first use.
- Run directories contain your prompts, diffs and file copies. They live
  outside the target repo by design; keep them out of version control
  (see `.gitignore`) and treat them like working documents — the injected
  rules tell agents never to write secrets into `PROGRESS.md`, but
  prompts you supply are copied verbatim.
- Checkpoints are on the same persistent home/storage as the run dir.
  They survive reboots of that host; they are not an off-host backup.

## Limitations

- The agent's internal reasoning is not saved — only files, commits,
  checkpoints, the original prompt and the decision log. A resumed agent
  must re-read those and reconstruct context (the resume prompt makes it
  do exactly that).
- If the agent never writes decision-log entries, resume still works,
  just with less context.
- Boot-age risk is a heuristic display only; nothing enforces it.

## Origin

Built for a personal setup where an agent VM is replaced roughly every
couple of hours and delegations run up to an hour. The measured reboot
statistics and the surrounding automation (watchers, auto-resume) from
that setup are intentionally not included — what remains is the portable
core. Dry-run kill tests (start → kill → checkpoint survives → interrupt
detected → resume prompt generated) pass for both wrappers.

## License

MIT — see [LICENSE](LICENSE).
