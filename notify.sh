# shellcheck shell=bash
#
# notify.sh — the Telegram notification.
#
# Origin: telegram_configured/telegram_send taken verbatim from
# lib/common-lib.sh of backup-docker-db. New here: notify_init, which reads the
# credentials from ONE file shared by every script on the host instead of a
# copy of the token in each global.conf.
#
# Configuration, in order of precedence:
#   1. TELEGRAM_BOT_TOKEN / TELEGRAM_CHAT_ID already set (e.g. directly in
#      global.conf) — always win, so a repo can migrate on its own schedule.
#   2. TELEGRAM_CONF=<path> in global.conf — that file is sourced and should
#      contain nothing but the two variables. Keep it 0600 root:root; it holds
#      a bot token that can post into your chat.
# Leaving both unset (or at "xxx") disables notifications without any other
# change.
#
# Needs: log.sh.

notify_init() {
  # Call once, after global.conf was sourced and before the first send.
  # A TELEGRAM_CONF that is set but unreadable is an ERROR, not silence: a
  # backup that has quietly stopped reporting is the failure mode this whole
  # notification exists to prevent.
  [[ -n "${TELEGRAM_CONF:-}" ]] || return 0
  if [[ -n "${TELEGRAM_BOT_TOKEN:-}" && -n "${TELEGRAM_CHAT_ID:-}" ]]; then
    log_info "Telegram credentials set in the global configuration — TELEGRAM_CONF not read"
    return 0
  fi
  if [[ ! -r "$TELEGRAM_CONF" ]]; then
    log_error "TELEGRAM_CONF is set but not readable for user '$(id -un)': $TELEGRAM_CONF — no notifications will be sent"
    return 1
  fi
  # shellcheck source=/dev/null
  if ! source "$TELEGRAM_CONF"; then
    log_error "TELEGRAM_CONF could not be read: $TELEGRAM_CONF"
    return 1
  fi
  return 0
}

telegram_configured() {
  [[ -n "${TELEGRAM_BOT_TOKEN:-}" && -n "${TELEGRAM_CHAT_ID:-}" \
     && "${TELEGRAM_BOT_TOKEN}" != "xxx" && "${TELEGRAM_CHAT_ID}" != "xxx" ]]
}

telegram_send() {
  # telegram_send <text>
  local text="$1"
  if ! telegram_configured; then
    log_info "Telegram not configured, notification skipped"
    return 0
  fi
  # Telegram limit: 4096 characters.
  text="${text:0:4096}"
  if ! curl -s --max-time 30 \
      -o /dev/null \
      "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage" \
      --data-urlencode "chat_id=${TELEGRAM_CHAT_ID}" \
      --data-urlencode "text=${text}"; then
    # Not log_error: a failed notification must not itself flip the run's
    # result (and the message reporting it has already been composed).
    _log_emit "ERROR" "Telegram notification could not be sent"
  fi
}

notify_check_binaries() {
  # The curl half of every script's check_binaries — reporting a missing curl
  # at the START of the run, not when the final notification silently fails.
  local p
  telegram_configured || return 0
  if p="$(command -v curl 2>/dev/null)"; then
    log_info "curl found: $p (Telegram notifications enabled)"
  else
    log_error "Telegram is configured, but curl not found — notifications will not be sent"
  fi
}
