# shellcheck shell=bash
#
# lock.sh — advisory single-instance lock for a run.
#
# Origin: acquire_lock() taken verbatim from backup-docker-db.sh (backup-tar.sh
# carried a byte-identical copy). Only the lock file became a parameter, so a
# script that keeps no LOG_DIR can still use it.
#
# Needs: log.sh (log_info / log_error).

acquire_lock() {
  # acquire_lock [lock-file] — default "$LOG_DIR/.lock".
  #
  # A second run started while the first is still working would write into the
  # same target directory and could leave a completion marker claiming a
  # half-finished state is complete. flock is advisory and free; where it does
  # not exist the run continues (and says so) rather than refusing to work.
  local lock_file="${1:-${LOG_DIR:-.}/.lock}"
  if ! command -v flock >/dev/null 2>&1; then
    log_info "flock not available — running without a concurrency lock"
    return 0
  fi
  # Checked before the exec: a redirection error on "exec" terminates a
  # non-interactive shell outright, and a missing lock must not be fatal.
  if ! touch "$lock_file" 2>/dev/null; then
    log_info "Lock file not writable ($lock_file) — running without a concurrency lock"
    return 0
  fi
  # Fixed descriptor 9 (used nowhere else) rather than the "{fd}>" form, which
  # needs bash >= 4.1. The lock is held until the script exits and the
  # descriptor is closed; append mode so the file is never truncated.
  exec 9>>"$lock_file"
  if ! flock -n 9; then
    log_error "Another run is still in progress (lock: $lock_file) — aborting"
    return 1
  fi
  return 0
}
