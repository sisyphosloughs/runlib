# shellcheck shell=bash
#
# run.sh — the skeleton of an unattended run: start, signal handling, the
# per-object worker loop, and the closing summary + notification + exit code.
#
# Origin: docker-db-dump.sh and tar-backup.sh carried this skeleton twice, word
# for word, differing only in the nouns they used. Those nouns are now
# variables, so each script keeps speaking its own language while running the
# same code.
#
# Set BEFORE run_traps / run_finish:
#   RUN_WHAT        Telegram headline, e.g. "DB dumps" / "tar backup"
#   RUN_LOG_NAME    closing log line,   e.g. "DB dump run" / "tar backup run"
#   RUN_UNIT        what is counted,    e.g. "Stacks" / "Paths"
#   RUN_OK_VERB     per-object success, e.g. "DB dump successful"
#   RUN_ABORT_HINT  what an abort means for whoever consumes the output
#   RUN_USES_MARKER 1 if the run publishes a completion marker (default 1)
#
# Optional, for a run whose summary needs more than the common shape:
#   RUN_TOTAL       how many objects were attempted, if that is not simply the
#                   number of loaded instances (a script looping over something
#                   else — repositories, say — sets its own count)
#   RUN_DATA_TEXT   replaces the "Data:" value, for a run where one byte count
#                   does not tell the story ("358.7 MB processed, 142.7 MB added")
#   RUN_EXTRA       extra lines between the count and "Data:", each ending in a
#                   newline. Use it to state WHAT was covered — a summary that
#                   never names its scope cannot show that something fell out of
#                   it.
#
# State it owns (read by the caller, e.g. to decide about the marker):
#   START_EPOCH HOSTNAME_SHORT CLEAN_EXIT RUN_REF
#   OK_INSTANCES[] INSTANCE_RESULTS[] TOTAL_BYTES MARKER_NOTE
#
# Needs: log.sh, util.sh, notify.sh, config.sh.

# Set by run_finish / an early-exit branch so the EXIT trap can tell a regular
# exit from an unexpected abort.
CLEAN_EXIT=0
# Reference file touched at the start of the run; an output file is "from this
# run" exactly if it is newer (used for the per-object sizes in the summary).
RUN_REF=""

OK_INSTANCES=()
INSTANCE_RESULTS=()
TOTAL_BYTES=0
MARKER_NOTE="not written"

run_init() {
  # run_init <log-dir> <log-prefix> — create this run's log file and the size
  # reference. Call as early as possible: BEFORE the configuration is read, so
  # configuration errors also end up in a log file instead of vanishing on
  # stderr. Returns 1 if the log file cannot be created (there is nowhere to
  # report that yet — the caller must fall back to stderr and give up).
  local log_dir="$1" prefix="$2"
  START_EPOCH="$(date +%s)"
  HOSTNAME_SHORT="$(hostname -s 2>/dev/null || hostname)"
  CLEAN_EXIT=0
  log_init "$log_dir" "$prefix" || return 1
  RUN_REF="$log_dir/.runref.$$"
  : > "$RUN_REF" || return 1
  return 0
}

run_cleanup() {
  # run_cleanup [reason] — $? must be read before anything else runs.
  local rc=$?
  local reason="${1:-exit code $rc}"
  # Only on an unexpected abort — a regular exit goes through run_finish().
  [[ "$CLEAN_EXIT" -eq 1 ]] && return 0
  # Set immediately: a signal handler ends in "exit", which runs the EXIT trap
  # on its way out — without this guard the alarm would be sent twice.
  CLEAN_EXIT=1

  if [[ "${RUN_USES_MARKER:-1}" -eq 1 ]]; then
    _log_emit "ERROR" "Unexpected abort ($reason) — the completion marker was NOT written"
  else
    _log_emit "ERROR" "Unexpected abort ($reason)"
  fi
  telegram_send "$(printf '❌ [%s] %s ABORTED\n\n%s\n\n--- Log (last 50 lines) ---\n%s' \
    "$HOSTNAME_SHORT" "${RUN_WHAT:-Run}" "${RUN_ABORT_HINT:-}" "$(log_tail)")"
  [[ -n "$RUN_REF" ]] && rm -f "$RUN_REF"
  return 0
}

run_traps() {
  # Register as soon as the Telegram credentials are known, so a configuration
  # error from here on also raises an alarm instead of failing silently under
  # cron.
  #
  # On a signal, stop for real instead of resuming where the run was
  # interrupted: a half-written target must not continue towards a completion
  # marker.
  trap run_cleanup EXIT
  trap 'run_cleanup "interrupted (SIGINT)"; exit 130' INT
  trap 'run_cleanup "terminated (SIGTERM)"; exit 143' TERM
}

run_end() {
  # run_end [exit-code] — leave WITHOUT the abort notification, for the paths
  # that end a run deliberately before any work is done (--list, --dry-run, a
  # lock held by another run).
  CLEAN_EXIT=1
  [[ -n "$RUN_REF" ]] && rm -f "$RUN_REF"
  exit "${1:-0}"
}

run_worker_loop() {
  # run_worker_loop <worker-fn>
  #
  #   <worker-fn> <name> <conf> <index>
  #     Does the actual work for one object. It is called on the LEFT side of a
  #     pipeline, i.e. in a SUBSHELL — deliberately: a failure has to end THIS
  #     object and not the whole run, and the per-object variables (including
  #     arrays) cannot leak into the next one. It reads whatever else it needs
  #     from its own index-parallel arrays via <index>.
  #
  #     Inside the worker, logging goes through the domain library's stderr
  #     log(); log_info/log_error belong to the run level, would be written to
  #     the log file a second time by the pipe below, and could not report
  #     anything back across the subshell boundary anyway.
  local worker_fn="$1"
  local idx name conf title outdir start rc bytes dur

  for idx in "${!INSTANCE_NAMES[@]}"; do
    name="${INSTANCE_NAMES[$idx]}"
    conf="${INSTANCE_CONFS[$idx]}"
    title="${INSTANCE_TITLES[$idx]:-$name}"
    outdir="${INSTANCE_OUTDIRS[$idx]:-}"
    start="$(date +%s)"

    # The pipe merges the subshell's stdout and stderr into terminal and log
    # file in one place, so the details are visible live on a manual run and
    # not just in the file. PIPESTATUS[0] keeps the worker's exit code (not
    # tee's) — read it on the very next line.
    "$worker_fn" "$name" "$conf" "$idx" 2>&1 | tee -a "$LOG_FILE"
    rc="${PIPESTATUS[0]}"

    bytes="$(bytes_newer_than "$outdir" "$RUN_REF")"
    dur="$(human_duration "$(( $(date +%s) - start ))")"

    if [[ "$rc" -eq 0 ]]; then
      TOTAL_BYTES=$((TOTAL_BYTES + bytes))
      OK_INSTANCES+=("$name")
      INSTANCE_RESULTS+=("$title: ok — $(human_bytes "$bytes") in $dur")
      log_info "$name: ${RUN_OK_VERB:-successful} ($(human_bytes "$bytes"), $dur)"
    else
      INSTANCE_RESULTS+=("$title: FAILED (exit $rc)")
      log_error "$name: failed (exit $rc) — see the details above"
    fi
  done
}

run_finish() {
  # Summary to the log, one notification, and the run's exit code. Never
  # returns.
  local end_epoch duration_s duration_h err_count total ok results="" r e msg
  local marker_log="" marker_msg="" data_text extra

  end_epoch="$(date +%s)"
  duration_s="$((end_epoch - START_EPOCH))"
  duration_h="$(human_duration "$duration_s")"
  err_count="${#ERRORS[@]}"
  total="${RUN_TOTAL:-${#INSTANCE_NAMES[@]}}"
  ok="${#OK_INSTANCES[@]}"
  data_text="${RUN_DATA_TEXT:-$(human_bytes "$TOTAL_BYTES")}"
  extra="${RUN_EXTRA:-}"

  log_info "--- Summary ---"
  for r in "${INSTANCE_RESULTS[@]+"${INSTANCE_RESULTS[@]}"}"; do
    log_plain "  - $r"
    results+="  - ${r}"$'\n'
  done
  if [[ "$err_count" -gt 0 ]]; then
    log_info "Recorded errors ($err_count):"
    for e in "${ERRORS[@]}"; do
      log_plain "  - $e"
    done
  fi

  if [[ "${RUN_USES_MARKER:-1}" -eq 1 ]]; then
    marker_log=". Marker: $MARKER_NOTE"
    marker_msg="Marker: $MARKER_NOTE"$'\n'
  fi

  log_info "${RUN_LOG_NAME:-Run} completed. $err_count errors. Duration: ${duration_h}${marker_log}"

  if [[ "$err_count" -eq 0 ]]; then
    msg="$(printf '✅ [%s] %s completed\nDuration: %s\n%s: %d/%d successful\n%sData: %s\n%s\n%s' \
      "$HOSTNAME_SHORT" "${RUN_WHAT:-Run}" "$duration_h" "${RUN_UNIT:-Objects}" \
      "$ok" "$total" "$extra" "$data_text" "$marker_msg" "$results")"
  else
    msg="$(printf '❌ [%s] %s completed with errors\nDuration: %s\n%s: %d/%d successful\nErrors: %d\n%s%s\n%s\n--- Log (last 50 lines) ---\n%s' \
      "$HOSTNAME_SHORT" "${RUN_WHAT:-Run}" "$duration_h" "${RUN_UNIT:-Objects}" \
      "$ok" "$total" "$err_count" "$extra" "$marker_msg" "$results" "$(log_tail)")"
  fi
  telegram_send "$msg"

  CLEAN_EXIT=1
  [[ -n "$RUN_REF" ]] && rm -f "$RUN_REF"

  # Exit code 0 ONLY on a completely successful run — that is what the caller
  # (cron, a monitoring wrapper) evaluates.
  if [[ "$err_count" -gt 0 ]]; then
    exit 1
  fi
  exit 0
}
