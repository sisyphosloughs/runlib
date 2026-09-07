# shellcheck shell=bash
#
# cmd.sh — run a command and put it in the log, in one step.
#
# Why one step: a log line and the call it describes drift apart when they are
# written separately. tar-lib.sh used to log "${TAR_BIN} ${opts[*]}" two lines
# above executing "${tar_cmd[@]}" "${opts[@]}" — the nice/ionice prefixes were
# missing from the logged line and nobody noticed, because nothing tied the two
# together. cmd_run logs exactly the argument vector it then executes.
#
# The caller builds its command as an array and hands it over:
#
#   cmd_run "${tar_cmd[@]}" "${opts[@]}"
#   cmd_run docker exec -e OVR_PW="$DB_PASSWORD" "$cid" sh -c "$s" > "$target"
#
# HARD RULE: cmd_run never writes to stdout — the log line goes to STDERR only.
# Every caller redirects the command's stdout itself: into the dump file, into
# /dev/null, into restic's --json pipe. Those redirections must keep applying to
# the payload, never to a log line. This is the same contract the domain
# libraries' own log() has (see the header of tar-lib.sh): the worker subshell
# tees stdout+stderr into the log file in one place.
#
# Two things this module exists to get right, in ONE place:
#
#   Quoting.   "${opts[*]}" renders --use-compress-program plus "zstd -3 -T0" as
#              four separate-looking arguments — a line that documents a command
#              which never ran and cannot be copied.
#   Redaction. log_init makes the log world-readable (chmod 644) on the promise
#              that it holds "paths, sizes and instance names — no secrets", and
#              dump_postgres passes -e OVR_PW="$DB_PASSWORD". Without redaction
#              that promise breaks the first time someone sets DB_PASSWORD.

# Prefix for the logged line, so a command lines up with the other messages of
# its object ("containers: tar --create …"). Set it as a LOCAL in the function
# that runs the command, then it resets itself when that function returns:
#   local CMD_PREFIX="${name}: "
: "${CMD_PREFIX:=}"

# Additional names whose value must be redacted, on top of the built-in
# patterns below. Globs, matched against the name left of the "=".
CMD_REDACT_EXTRA=()

_cmd_is_secret_name() {
  # _cmd_is_secret_name <name> — 0 if <name> looks like it carries a credential.
  local name="$1" pat
  # A "…_FILE" name holds a PATH to a secret, not the secret. Those are worth
  # seeing in the log (they are what you check when a dump fails), so they are
  # excluded before the credential patterns are tried.
  case "$name" in
    *_FILE) return 1 ;;
  esac
  case "$name" in
    *PASS*|*SECRET*|*TOKEN*|*CREDENTIAL*|*_PW|PW|*_KEY|*APIKEY*) return 0 ;;
  esac
  for pat in "${CMD_REDACT_EXTRA[@]+"${CMD_REDACT_EXTRA[@]}"}"; do
    [[ -n "$pat" ]] || continue
    # shellcheck disable=SC2254  # $pat is meant to be used as a glob
    case "$name" in $pat) return 0 ;; esac
  done
  return 1
}

_cmd_needs_quote() {
  # _cmd_needs_quote <string> — 0 if it has to be quoted to survive a shell.
  case "$1" in
    "") return 0 ;;
    *[!A-Za-z0-9_@%+=:,./-]*) return 0 ;;
  esac
  return 1
}

cmd_quote() {
  # cmd_quote <string> — the string as ONE shell word, quoted only where it has
  # to be. Public on purpose: a caller that ASSEMBLES a command for another
  # shell (the database dumps build an "sh -c" line) has to use the same rule
  # the log uses, or the logged line and the executed one drift apart again.
  local s="$1" q="'" bs
  # shellcheck disable=SC1003  # bs is ONE backslash, not an escape
  bs='\'
  if _cmd_needs_quote "$s"; then
    printf "'%s'" "${s//$q/${q}${bs}${q}${q}}"
  else
    printf '%s' "$s"
  fi
}

_cmd_render() {
  # _cmd_render <arg> — redact, then quote, then print the finished token.
  # Redaction and quoting live in one function on purpose: chaining them through
  # two command substitutions would strip a trailing newline between the steps.
  local arg="$1" orig="$1" name value scheme rest userinfo nl n
  # shellcheck disable=SC1003  # bs is ONE backslash, not an escape
  local sq="'" bs='\'

  # --- redaction ----------------------------------------------------------
  # NAME=VALUE, as passed to "docker exec -e" or as an environment prefix.
  case "$arg" in
    [A-Za-z_]*=*)
      name="${arg%%=*}"
      value="${arg#*=}"
      if [[ -z "$value" ]]; then
        # An empty value stays visible — the log should distinguish "was not
        # set" from "was set and hidden" — but it is written with explicit
        # empty quotes. A bare "OVR_PW=" followed by the next argument reads as
        # if that argument were the value, which turns a harmless line into a
        # false credential alarm.
        arg="${name}=''"
      elif _cmd_is_secret_name "$name"; then
        arg="${name}=***"
      fi
      ;;
  esac
  # Credentials inside a URL: scheme://user:pass@host -> scheme://user:***@host.
  # restic accepts rest:https://user:pass@host, and the repository URL comes
  # from repos.conf, so it is not under this code's control.
  case "$arg" in
    *://*:*@*)
      scheme="${arg%%://*}"
      rest="${arg#*://}"
      userinfo="${rest%%@*}"
      case "$userinfo" in
        */*) ;;                     # the "@" is in the path, not user info
        *:*) arg="${scheme}://${userinfo%%:*}:***@${rest#*@}" ;;
      esac
      ;;
  esac

  # --- quoting ------------------------------------------------------------
  # Whether quotes are NEEDED is decided on the ORIGINAL argument, while what
  # gets printed is the redacted one. Otherwise the "*" of the *** placeholder
  # would pull quotes around a value that never needed any, and the line would
  # imply the real password contained shell metacharacters.
  # A multi-line argument is the inline "sh -c" script of the database dumps.
  # Printing eight lines of shell into the middle of a log line helps nobody, so
  # it is elided — VISIBLY, so the line is never mistaken for something to copy.
  case "$orig" in
    *"
"*)
      nl="${orig//[!$'\n']/}"       # keep only the newlines …
      n=$(( ${#nl} + 1 ))           # … to count the lines without forking
      printf "'<inline script, %s lines>'" "$n"
      return 0
      ;;
  esac
  if _cmd_needs_quote "$orig"; then
    # A single quote inside is closed, escaped and reopened — the '\'' idiom —
    # so the result can be pasted into a shell verbatim.
    printf "'%s'" "${arg//$sq/${sq}${bs}${sq}${sq}}"
  else
    printf '%s' "$arg"
  fi
}

cmd_format() {
  # cmd_format <argv...> — the command as ONE quoted, redacted line on stdout.
  # Pure: it neither logs nor runs anything. Use it to document a command that
  # is not executed right here; everything else should use cmd_run.
  local out="" arg
  for arg in "$@"; do
    if [[ -n "$out" ]]; then
      out="$out $(_cmd_render "$arg")"
    else
      out="$(_cmd_render "$arg")"
    fi
  done
  printf '%s' "$out"
}

cmd_run() {
  # cmd_run <argv...> — log the command, then execute it. Returns the command's
  # own exit status unchanged, so the caller's "|| rc=$?", "if …" and
  # PIPESTATUS[0] keep working exactly as they did around the bare call.
  if [[ "$#" -eq 0 ]]; then
    printf '%s %-7s %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "[ERROR]" \
      "cmd_run called without a command" >&2
    return 2
  fi
  printf '%s %-7s %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "[INFO]" \
    "${CMD_PREFIX}$(cmd_format "$@")" >&2
  "$@"
}
