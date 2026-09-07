# shellcheck shell=bash
#
# util.sh — small, dependency-free helpers: predicates, formatting, path maths.
#
# Origin: contains/is_truthy/human_duration/human_bytes/bytes_newer_than are
# taken verbatim from lib/common-lib.sh of backup-docker-db; abs_path/is_inside
# from backup-tar.sh, where they were the only correct containment check of the
# family (backup-docker-db.sh compared raw string prefixes, which a relative path
# or a "/../" defeats).
#
# Nothing here logs or exits — these are pure functions.

contains() {
  # contains <needle> <haystack...> — 0 if <needle> is among the arguments.
  local needle="$1"; shift
  local x
  for x in "$@"; do
    [[ "$x" == "$needle" ]] && return 0
  done
  return 1
}

is_truthy() {
  case "${1:-false}" in
    1|true|TRUE|True|yes|YES|Yes|on|ON) return 0 ;;
    *) return 1 ;;
  esac
}

human_duration() {
  # Seconds -> "4m32s"
  local secs="$1"
  printf '%dm%02ds' "$((secs / 60))" "$((secs % 60))"
}

human_bytes() {
  # Bytes -> "234 MB"
  local b="${1:-0}"
  # LC_ALL=C so the ".1f" decimal uses a dot (not a comma) regardless of locale.
  LC_ALL=C awk -v b="$b" 'BEGIN {
    split("B KB MB GB TB PB", u, " ");
    i = 1;
    while (b >= 1024 && i < 6) { b /= 1024; i++ }
    if (i == 1) printf "%d %s", b, u[i];
    else printf "%.1f %s", b, u[i];
  }'
}

bytes_newer_than() {
  # bytes_newer_than <dir> <reference-file> — total size of the files that
  # <dir> gained since <reference-file> was touched, i.e. what THIS run
  # produced. Always prints a number. Uses only POSIX find predicates so it
  # also works on a busybox host; "wc -c" per file (there are a handful) avoids
  # the "total" line that a single multi-file wc would add.
  local dir="$1" ref="$2"
  if [[ ! -d "$dir" || ! -e "$ref" ]]; then
    printf '0'
    return 0
  fi
  find "$dir" -maxdepth 1 -type f -newer "$ref" -exec wc -c {} \; 2>/dev/null \
    | awk '{ s += $1 } END { printf "%d", s + 0 }'
}

abs_path() {
  # abs_path <path> — absolute path, WITHOUT requiring it to exist (a target
  # directory is usually created later). Used for the containment checks, where
  # a relative path or a "/../" would otherwise defeat the comparison.
  local p="$1"
  if command -v realpath >/dev/null 2>&1 && realpath -m / >/dev/null 2>&1; then
    realpath -m "$p" 2>/dev/null && return 0
  fi
  case "$p" in
    /*) printf '%s' "$p" ;;
    *)  printf '%s' "$PWD/$p" ;;
  esac
}

is_inside() {
  # is_inside <inner> <outer> — 0 if <inner> lies in <outer> (or is <outer>).
  # The trailing slashes keep "/data/backup-old" from counting as inside
  # "/data/backup".
  local inner outer
  inner="$(abs_path "$1")"; outer="$(abs_path "$2")"
  [[ "${inner%/}/" == "${outer%/}/"* ]]
}
