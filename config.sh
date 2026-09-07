# shellcheck shell=bash
#
# config.sh — the "one *.conf per object" configuration loader.
#
# Origin: the common skeleton of three loaders that had grown apart —
# load_stacks() (docker-db-dump.sh), load_paths() (tar-backup.sh) and
# load_instances() (restic-backup.sh). They agreed on everything except the
# domain checks, so those are the part that stays with the caller.
#
# The contract for a configuration directory is unchanged: one <name>.conf per
# object, the file name (without ".conf") IS the object's name — its log label,
# its sub-directory under the target, and the prefix of whatever it produces.
# Adding an object means adding a file, never touching a script.
#
# Records filled here, index-parallel and read by run.sh:
#   INSTANCE_NAMES[]    the object's name
#   INSTANCE_CONFS[]    path of its *.conf
#   INSTANCE_OUTDIRS[]  where it writes (filled by <validate-fn>; used to
#                       measure what the run produced)
#   INSTANCE_TITLES[]   label for the summary line, e.g. "solidtime (postgres)";
#                       filled by <validate-fn>, defaults to the name
#
# Wording knobs, so a script keeps speaking its own domain language:
#   INSTANCE_LABEL      "Stack" / "Path" / "Instance"   (default "Instance")
#   INSTANCE_LABEL_LC   "stack" / "path" / "instance"   (default "instance")
#   INSTANCE_OPT        the CLI flag naming one object  (default "--instance")
#
# Needs: log.sh, util.sh.

INSTANCE_NAMES=()
INSTANCE_CONFS=()
INSTANCE_OUTDIRS=()
INSTANCE_TITLES=()

instances_load() {
  # instances_load <dir> <reset-fn> <validate-fn> [selected-name...]
  #
  #   <reset-fn> <name>
  #     Resets every per-object variable to its default so a value from one file
  #     never leaks into the next, and may pre-seed defaults derived from <name>
  #     (e.g. STACK_DIR="$STACKS_BASE/$name") that the configuration can then
  #     refer to — and still override.
  #
  #   <validate-fn> <name> <conf>
  #     Checks the domain requirements and records whatever the run needs
  #     (target directory, engine, source, …). Returns 0 to accept the object,
  #     non-zero to skip it. It writes its OWN messages: an unusable
  #     configuration must say what is wrong with it in the domain's own words,
  #     and a log_error there is what suppresses the completion marker.
  #
  # A configuration that cannot be used is an ERROR, not a silent skip. Only an
  # explicit ENABLED=false is a deliberate skip.
  local dir="$1" reset_fn="$2" validate_fn="$3"
  shift 3
  local selected=("$@")
  local conf name found=0 sel
  local label="${INSTANCE_LABEL:-Instance}"
  local label_lc="${INSTANCE_LABEL_LC:-instance}"
  local opt="${INSTANCE_OPT:---instance}"

  [[ -d "$dir" ]] || fatal "${label} configuration directory not found: $dir"

  for conf in "$dir"/*.conf; do
    [[ -e "$conf" ]] || continue                 # no *.conf present at all
    case "$conf" in *.example) continue ;; esac  # skip templates (defensive)
    name="${conf##*/}"; name="${name%.conf}"
    found=$((found + 1))

    # Selection: restrict the run to the named objects. A partial run never
    # writes the completion marker — that is the caller's business, not ours.
    if [[ "${#selected[@]}" -gt 0 ]] && ! contains "$name" "${selected[@]}"; then
      continue
    fi

    # Safety net in case a <reset-fn> forgets it: an object is enabled unless
    # its configuration says otherwise.
    ENABLED="true"
    "$reset_fn" "$name"

    # shellcheck source=/dev/null
    if ! source "$conf"; then
      log_error "${label} '$name': $conf could not be read — skipped"
      continue
    fi

    if ! is_truthy "$ENABLED"; then
      log_info "${label} '$name': ENABLED is not true — skipped on purpose"
      continue
    fi

    "$validate_fn" "$name" "$conf" || continue

    INSTANCE_NAMES+=("$name")
    INSTANCE_CONFS+=("$conf")
    # Keep the four records index-parallel even when <validate-fn> filled
    # neither: the summary falls back to the plain name, and an unmeasured
    # object reports 0 bytes rather than shifting every later index.
    [[ "${#INSTANCE_OUTDIRS[@]}" -lt "${#INSTANCE_NAMES[@]}" ]] && INSTANCE_OUTDIRS+=("")
    [[ "${#INSTANCE_TITLES[@]}"  -lt "${#INSTANCE_NAMES[@]}" ]] && INSTANCE_TITLES+=("$name")
  done

  # A selected name without a matching configuration is a typo, not an empty run.
  for sel in "${selected[@]+"${selected[@]}"}"; do
    contains "$sel" "${INSTANCE_NAMES[@]+"${INSTANCE_NAMES[@]}"}" \
      || log_error "${opt} '$sel': no usable configuration $dir/$sel.conf"
  done

  [[ "$found" -gt 0 ]] \
    || fatal "No ${label_lc} configurations (*.conf) found in $dir"
  [[ "${#INSTANCE_NAMES[@]}" -gt 0 ]] \
    || fatal "No usable ${label_lc} configuration in $dir"
}

instances_record() {
  # instances_record <outdir> <title> — called from a <validate-fn> that has
  # just accepted an object, to fill the two optional records. Keeping it a
  # function (rather than appending to the arrays by hand) is what keeps them
  # index-parallel with INSTANCE_NAMES.
  INSTANCE_OUTDIRS+=("$1")
  INSTANCE_TITLES+=("${2:-}")
}
