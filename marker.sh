# shellcheck shell=bash
#
# marker.sh — the completion marker a run publishes for whatever consumes its
# output (a backup host pulling the tree, a monitoring check).
#
# Origin: write_marker() from docker-db-dump.sh and tar-backup.sh, which were
# word-for-word identical apart from three key names — those are now arguments.
#
# Needs: log.sh.

write_marker() {
  # write_marker <marker-path> <group> <generator> [key=value ...]
  #
  # Written atomically (temp file + mv inside the marker's own directory, i.e.
  # the same filesystem) so a reader never sees a half-written marker, and only
  # after a completely error-free run — that decision belongs to the caller.
  #
  # A failed run must deliberately leave an EXISTING older marker untouched
  # instead of deleting it: a reader judges by age, so it keeps seeing the old
  # timestamp, still has yesterday's valid output, and raises the alarm as soon
  # as its freshness threshold is exceeded. Deleting it would turn a single
  # failed object into a total backup outage.
  local marker_path="$1" group="$2" generator="$3"
  shift 3
  local tmp="${marker_path}.tmp.$$"
  local kv

  # Get the data onto the disk before the marker claims it is there: after a
  # crash the marker must never outlive the data it vouches for.
  command -v sync >/dev/null 2>&1 && sync

  if ! {
    printf 'completed_at=%s\n'    "$(date '+%Y-%m-%dT%H:%M:%S%z')"
    printf 'completed_epoch=%s\n' "$(date +%s)"
    printf 'host=%s\n'            "${HOSTNAME_SHORT:-$(hostname -s 2>/dev/null || hostname)}"
    for kv in "$@"; do
      printf '%s\n' "$kv"
    done
    printf 'generator=%s\n'       "$generator"
  } > "$tmp"; then
    log_error "Completion marker could not be written: $tmp"
    rm -f "$tmp"
    return 1
  fi

  [[ -n "$group" ]] && chgrp "$group" "$tmp" 2>/dev/null

  if ! mv -f "$tmp" "$marker_path"; then
    log_error "Completion marker could not be moved into place: $marker_path"
    rm -f "$tmp"
    return 1
  fi
  log_info "Completion marker written: $marker_path"
  return 0
}
