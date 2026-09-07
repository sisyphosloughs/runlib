# runlib

A small Bash library for **unattended runs** — the kind a cron job or a
systemd timer starts at night and nobody watches: one log file per run, an
error account that decides the exit code, a single-instance lock, a
configuration directory of one file per object, and one notification at the
end that says what happened.

It carries no domain logic of its own. It came out of three backup scripts that
had each grown their own copy of the same skeleton, but nothing here is about
backups — any script that runs unattended and has to report for itself can use
it.

## Using it

The library is meant to be a **git submodule** of the script that uses it:

```bash
git submodule add git@github.com:sisyphosloughs/runlib.git lib/runlib
```

Then source the single entry point:

```bash
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/runlib/runlib.sh"
```

A fresh clone of the consuming repo needs `git clone --recurse-submodules`; an
existing one needs `git submodule update --init`. To move to a newer runlib:

```bash
git submodule update --remote lib/runlib
git add lib/runlib && git commit -m "runlib: update"
```

## Modules

| File | What it provides |
|---|---|
| `log.sh` | `LOG_FILE`, `ERRORS[]`, `log_init`, `log_rotate`, `log_info/warn/error/plain`, `fatal`, `log_tail` |
| `util.sh` | `contains`, `is_truthy`, `human_duration`, `human_bytes`, `bytes_newer_than`, `abs_path`, `is_inside` |
| `cmd.sh` | `cmd_run`, `cmd_format`, `cmd_quote` — run a command and put it in the log, in one step |
| `lock.sh` | `acquire_lock` — advisory flock, degrades to a warning where flock is missing |
| `notify.sh` | `notify_init`, `telegram_configured`, `telegram_send`, `notify_check_binaries` |
| `config.sh` | `instances_load`, `instances_record` — the "one *.conf per object" loader |
| `run.sh` | `run_init`, `run_traps`, `run_end`, `run_worker_loop`, `run_finish` |
| `marker.sh` | `write_marker` — an atomically published completion marker |

`runlib.sh` sources all of them in the order they depend on each other.

## The two channels

runlib deliberately provides **no bare `log()`**. Run-level messages
(`log_info`, …) go to stdout **and** the log file. A script's own domain library
brings its own `log()` that writes to **stderr only**, because such libraries
return values through stdout (`cid="$(_resolve_container …)"`) and a diagnostic
on that channel would corrupt the value. Both libraries end up in the same
shell, so the names have to stay apart.

## Documenting the command that ran

`cmd_run` logs an argument vector and then executes it. One call, so the logged
line cannot drift from the real one — the failure mode it exists to prevent:

```bash
local CMD_PREFIX="${name}: "        # optional, prefixes the line
cmd_run "${tar_cmd[@]}" "${opts[@]}"
```

It returns the command's own exit status, so `|| rc=$?`, `if …` and
`PIPESTATUS[0]` keep working exactly as they did around the bare call.

**`cmd_run` never writes to stdout** — the line goes to stderr only. That is
what makes it safe to wrap a command whose stdout carries payload:

```bash
cmd_run docker exec … "$cid" sh -c "$s" > "$target"   # dump, not a log line
cmd_run "$TAR_BIN" --list --file "$a" >/dev/null      # listing discarded
cmd_run restic … --json | parse_summary               # JSON stays JSON
```

Two things it gets right that a hand-written log line does not:

- **Quoting.** `"${opts[*]}"` renders `--use-compress-program` plus
  `zstd -3 -T0` as four separate-looking arguments. `cmd_format` quotes only
  what needs it, so the line says what ran and can be pasted into a shell.
- **Redaction.** `NAME=VALUE` pairs whose name looks like a credential become
  `NAME=***`, and `scheme://user:pass@host` becomes `scheme://user:***@host`.
  An *empty* value stays visible, so the log still distinguishes "was not set"
  from "was set and hidden". A `…_FILE` name is a path, not a secret, and is
  left alone. Extend the name patterns through `CMD_REDACT_EXTRA`.

This matters because `log_init` makes the log world-readable (`chmod 644`) on
the promise that it holds paths and sizes, not secrets.

`cmd_format` alone returns the formatted line on stdout, for the rare case
where something must be documented without being run here.

`cmd_quote` returns ONE argument as a shell word, quoted only where it has to
be. Use it when a caller assembles a command line for another shell — the
database dumps build an `sh -c` line whose user and database names come from
the container. Quoting them with the same rule the log uses is what keeps the
logged line and the executed line the same text.

## Shape of a script using it

```bash
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/runlib/runlib.sh"

RUN_WHAT="tar backup"          # Telegram headline
RUN_LOG_NAME="tar backup run"  # closing log line
RUN_UNIT="Paths"               # what is counted
RUN_OK_VERB="archive successful"
RUN_ABORT_HINT="The target directory is not consistent; do not rely on this run."
INSTANCE_LABEL="Path"; INSTANCE_LABEL_LC="path"

run_init "$SCRIPT_DIR/logs" "tar-backup" \
  || { echo "FATAL: cannot create the log file" >&2; exit 1; }
source "$SCRIPT_DIR/global.conf"
notify_init
run_traps

instances_load "$INSTANCES_DIR" reset_path_vars validate_path "${SELECTED[@]+"${SELECTED[@]}"}"
acquire_lock || run_end 1
run_worker_loop archive_one_path
run_finish
```

`reset_path_vars <name>` resets the per-object variables; `validate_path <name>
<conf>` checks the domain requirements, calls `instances_record <outdir>
<title>` and returns non-zero to skip an object. Both write their own messages,
in their own domain's words — that is what keeps the logs specific while the
skeleton stays shared.

## Telegram

Credentials come from one file per host rather than a copy in every script's
configuration. Point `TELEGRAM_CONF` at it and call `notify_init`:

```bash
# /etc/runlib/telegram.conf   —   chmod 600, owned by root
TELEGRAM_BOT_TOKEN="…"
TELEGRAM_CHAT_ID="…"
```

Credentials set directly in the environment still win, so a script can migrate
on its own schedule. Leaving both unset (or at `"xxx"`) disables notifications
without any other change.

## Requirements

Bash, plus the coreutils any of these scripts already assume (`date`, `find`,
`tee`, `awk`). `flock` and `curl` are optional — a missing `flock` costs the
lock (with a warning), a missing `curl` the notification (with an error, at the
start of the run rather than at its end).

## Licence

MIT — see `LICENSE`.
