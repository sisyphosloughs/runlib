# shellcheck shell=bash
#
# log.sh — the per-run log file and the error account.
#
# Origin: extracted verbatim from lib/common-lib.sh of backup-docker-db, which was
# the canonical copy shared by the backup scripts. Behaviour is unchanged.
#
# This is NOT a standalone program: source it (or runlib.sh) at the top of a
# script. Load it FIRST — every other runlib module uses log_info/log_error.
#
# Deliberately absent: a bare log(). A script's domain library (db-dump-lib.sh,
# tar-lib.sh, …) brings its own, stderr-only log() and both end up in the SAME
# shell. Keeping the names apart is not cosmetic: those libraries return values
# through stdout ("cid=$(_resolve_container …)", "spec=$(compressor_spec …)"),
# so their diagnostics must stay on stderr, while the run-level messages here go
# to stdout AND the log file.
#
# Provided (read at call time by the other modules):
#   LOG_FILE   set by log_init; every message is appended here
#   ERRORS     array, appended to by log_error — drives the run's summary, its
#              exit code and whether a completion marker may be written at all

# Until log_init runs, messages go to the terminal only instead of tripping
# "set -u" or creating a stray file.
LOG_FILE="${LOG_FILE:-/dev/null}"
ERRORS=()

log_init() {
  # log_init <log-dir> <prefix> — create the log directory and this run's log
  # file ("<prefix>-<timestamp>.log", one per run) and set LOG_FILE / RUN_TS.
  # Returns 1 without logging (there is no log yet) if that is not possible;
  # the caller has to fall back to stderr.
  local dir="$1" prefix="$2"
  mkdir -p "$dir" || return 1
  RUN_TS="$(date +%Y-%m-%dT%H-%M-%S)"
  LOG_FILE="$dir/${prefix}-${RUN_TS}.log"
  touch "$LOG_FILE" || return 1
  # The script runs as root, so the log would default to root:root 0600 and be
  # unreadable for the normal user (and thus not viewable/syncable). Logs carry
  # paths, sizes and instance names — no secrets — so make them world-readable.
  chmod 644 "$LOG_FILE" 2>/dev/null || true
}

log_rotate() {
  # log_rotate <log-dir> <prefix> <days> — the script keeps its own logs
  # bounded, so no logrotate configuration is needed on the host.
  local dir="$1" prefix="$2" days="$3"
  [[ -d "$dir" ]] || return 0
  find "$dir" -maxdepth 1 -type f -name "${prefix}-*.log" -mtime +"$days" \
    -delete 2>/dev/null
  return 0
}

_log_emit() {
  # "<ts> [LEVEL] msg", padded to width 7 so the messages line up. Written to
  # stdout and appended to the log file in one go.
  local level="$1"; shift
  printf '%s %-7s %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "[${level}]" "$*" \
    | tee -a "$LOG_FILE"
}

log_info() { _log_emit "INFO" "$@"; }

# A warning is worth seeing but does NOT make the run fail — unlike log_error it
# is not recorded in ERRORS.
log_warn() { _log_emit "WARN" "$@"; }

log_error() {
  _log_emit "ERROR" "$@"
  ERRORS+=("$*")
}

# Continuation/detail line without a level prefix (lists in the summary).
log_plain() { printf '%s\n' "$*" | tee -a "$LOG_FILE"; }

# Fatal problem during initialisation: log it and give up. The caller's EXIT
# trap turns this into the "aborted" notification once it is registered.
fatal() {
  _log_emit "ERROR" "$@"
  exit 1
}

log_tail() {
  # log_tail [lines] — tail of the current log, for the notification body.
  tail -n "${1:-50}" "$LOG_FILE" 2>/dev/null
}
