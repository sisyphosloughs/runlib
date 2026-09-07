# shellcheck shell=bash
#
# runlib.sh — entry point. Source this one file to get the whole library:
#
#   SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
#   source "$SCRIPT_DIR/lib/runlib/runlib.sh"
#
# Order matters: log.sh first, because every other module reports through
# log_info/log_error; util.sh second, because the rest uses contains/is_truthy;
# cmd.sh third, because it is what the domain libraries run their commands with.
#
# What runlib deliberately does NOT provide is a bare log(). A script's domain
# library (db-dump-lib.sh, tar-lib.sh, …) brings its own, stderr-only log() and
# both end up in the same shell — see the header of log.sh for why the two
# channels must stay apart.

_RUNLIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=log.sh
source "$_RUNLIB_DIR/log.sh"
# shellcheck source=util.sh
source "$_RUNLIB_DIR/util.sh"
# shellcheck source=cmd.sh
source "$_RUNLIB_DIR/cmd.sh"
# shellcheck source=lock.sh
source "$_RUNLIB_DIR/lock.sh"
# shellcheck source=notify.sh
source "$_RUNLIB_DIR/notify.sh"
# shellcheck source=config.sh
source "$_RUNLIB_DIR/config.sh"
# shellcheck source=marker.sh
source "$_RUNLIB_DIR/marker.sh"
# shellcheck source=run.sh
source "$_RUNLIB_DIR/run.sh"

# Version of the library, for a script that wants to log what it is running.
# shellcheck disable=SC2034  # read by the sourcing script, not here.
RUNLIB_VERSION="0.1.0"
