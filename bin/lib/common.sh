# shellcheck shell=bash
#
# Shared library for the omarchy-focus-gate CLI scripts.
#
# Every script sources this first: it resolves paths, loads config and
# state (creating sane defaults the first time), recomputes the effective
# date and resets daily counters when the day rolls over, and exposes small
# helpers for reading/writing state JSON and firing notifications.
#
# All functions/logic here must be idempotent: safe to re-run, safe to call
# any number of times.

set -o pipefail

# ---------------------------------------------------------------------------
# Paths
# ---------------------------------------------------------------------------

# Root of the plugin install (wherever this checkout lives). Consumed by the
# install/uninstall hooks; flagged unused when this library is analysed on
# its own.
# shellcheck disable=SC2034
FG_PLUGIN_DIR="$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"

FG_STATE_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/omarchy/focus-gate"
FG_STATE_FILE="$FG_STATE_DIR/state.json"
FG_CONFIG_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/omarchy-focus-gate"
FG_CONFIG_FILE="$FG_CONFIG_DIR/config.json"

# ---------------------------------------------------------------------------
# Defaults (mirrors the JSON shipped by the install hook)
# ---------------------------------------------------------------------------

FG_DEFAULT_CONFIG='{
  "required_study_seconds": 10800,
  "daily_game_allowance_seconds": 3600,
  "reset_hour_local": 5,
  "warning_seconds_before_cutoff": 600,
  "tracked_game_processes": [
    "steam",
    "lutris",
    "heroic",
    "bottles",
    "sober",
    "t-launcher",
    "retroarch",
    "minecraft-launcher",
    "prismlauncher"
  ],
  "tracked_game_commands": [
    "tlauncher",
    "TLauncher",
    "minecraft"
  ]
}'

FG_DEFAULT_STATE='{
  "effective_date": "1970-01-01",
  "study_seconds_today": 0,
  "game_seconds_used_today": 0,
  "unlocked": false,
  "study_session_active": false
}
'

# Cap for elapsed-time accrual per daemon tick. A tick delayed by suspend,
# hibernation, or a stalled timer could otherwise credit the whole offline
# gap as study/game time. Ticks run every 30s, so a gap beyond 5 minutes is
# treated as suspend and not counted. Consumed by omarchy-focus-gate-daemon.
# shellcheck disable=SC2034
FG_ELAPSED_CAP_SECONDS=300

# ---------------------------------------------------------------------------
# Config and state loaders
# ---------------------------------------------------------------------------

fg_ensure_dirs() {
  mkdir -p "$FG_STATE_DIR" "$FG_CONFIG_DIR"
}

fg_config_exists() {
  [[ -f $FG_CONFIG_FILE ]]
}

# Load the user config. Never fails: creates a default config on first run
# (without clobbering an existing one) and falls back to defaults for any
# missing or malformed field.
fg_config() {
  if [[ -f $FG_CONFIG_FILE ]]; then
    jq -r \
      --argjson required  10800 \
      --argjson allowance 3600  \
      --argjson reset_hour 5   \
      --argjson warning   600  \
      '. | {
        required_study_seconds: (.required_study_seconds // $required),
        daily_game_allowance_seconds: (.daily_game_allowance_seconds // $allowance),
        reset_hour_local: (.reset_hour_local // $reset_hour),
        warning_seconds_before_cutoff: (.warning_seconds_before_cutoff // $warning),
        tracked_game_processes: (.tracked_game_processes // ["steam", "lutris", "heroic", "bottles", "sober", "t-launcher", "retroarch", "minecraft-launcher", "prismlauncher"]),
        tracked_game_commands: (.tracked_game_commands // ["tlauncher", "TLauncher", "minecraft"])
      }' "$FG_CONFIG_FILE"
  else
    printf '%s\n' "$FG_DEFAULT_CONFIG"
  fi
}

# Load the runtime state. Never fails: creates a fresh default state on
# first run and backs up a corrupt file before resetting it.
fg_state() {
  fg_ensure_dirs
  if [[ ! -f $FG_STATE_FILE ]]; then
    printf '%s\n' "$FG_DEFAULT_STATE" > "$FG_STATE_FILE"
  elif ! jq -e . "$FG_STATE_FILE" >/dev/null 2>&1; then
    mv -f "$FG_STATE_FILE" "$FG_STATE_FILE.corrupt-$(date +%s)" 2>/dev/null || true
    printf '%s\n' "$FG_DEFAULT_STATE" > "$FG_STATE_FILE"
  fi
  jq -c '. | {
    effective_date: (.effective_date // ""),
    study_seconds_today: (.study_seconds_today // 0),
    game_seconds_used_today: (.game_seconds_used_today // 0),
    unlocked: (.unlocked // false),
    study_session_active: (.study_session_active // false),
    last_tick_epoch: (.last_tick_epoch // 0),
    warning_announced: (.warning_announced // false)
  }' "$FG_STATE_FILE"
}

# Atomically write state JSON (temp file + rename so the QML file watcher
# and concurrent scripts never observe a half-written file).
#
# Accepts keys as arguments in KEY=VALUE form and starts from the current
# state so unknown internal fields survive untouched.
fg_state_write() {
  local arg key value
  local filter='.'
  local jq_args=()
  for arg in "$@"; do
    key="${arg%%=*}"
    value="${arg#*=}"
    case "$key" in
      effective_date)
        jq_args+=(--arg "$key" "$value")
        filter+=" | .$key = \$$key"
        ;;
      study_seconds_today | game_seconds_used_today \
        | unlocked | study_session_active | last_tick_epoch | warning_announced)
        jq_args+=(--argjson "$key" "$value")
        filter+=" | .$key = \$$key"
        ;;
    esac
  done
  [[ $filter != '.' ]] || return 0
  fg_ensure_dirs
  (
    flock 9
    jq -c "$filter" "${jq_args[@]}" "$FG_STATE_FILE" > "$FG_STATE_FILE.tmp" || exit 1
    mv -f "$FG_STATE_FILE.tmp" "$FG_STATE_FILE"
  ) 9>"$FG_STATE_DIR/.lock"
}

# ---------------------------------------------------------------------------
# Effective date
# ---------------------------------------------------------------------------

# The "effective day" rolls over at reset_hour_local (default 05:00), not
# midnight. Before the reset hour the effective day is still yesterday.
fg_effective_date() {
  local reset_hour
  reset_hour=$(fg_config | jq -r '.reset_hour_local // 5')
  local hour
  hour=$(date +%-H)
  if (( hour < reset_hour )); then
    date -d 'yesterday' +%F
  else
    date +%F
  fi
}

# Call this before reading state for any decision: if the day rolled over,
# reset every daily counter and lock the gate again.
fg_reset_if_day_changed() {
  local expected
  expected=$(fg_effective_date)
  local current
  current=$(fg_state | jq -r '.effective_date')
  if [[ $current != "$expected" ]]; then
    fg_state_write \
      effective_date="$expected" \
      study_seconds_today=0 \
      game_seconds_used_today=0 \
      unlocked=false \
      warning_announced=false \
      last_tick_epoch="$(date +%s)"
  fi
}

# ---------------------------------------------------------------------------
# Formatting
# ---------------------------------------------------------------------------

# Compact duration label for notifications/status text ("10800" -> "3h").
fg_fmt_time() {
  local sec="$1"
  local h m
  h=$((sec / 3600))
  m=$(((sec % 3600) / 60))
  if (( h > 0 )); then
    if (( m > 0 )); then printf '%dh %dm' "$h" "$m"; else printf '%dh' "$h"; fi
  else
    printf '%dm' "$m"
  fi
}

# ---------------------------------------------------------------------------
# Notifications
# ---------------------------------------------------------------------------

# Fire a desktop notification if notify-send exists; silent otherwise.
# Never fails the caller: a headless tick must not die on a missing
# notification daemon.
fg_notify() {
  local urgency="$1"
  local summary="$2"
  local body="$3"
  command -v notify-send > /dev/null 2>&1 || return 0
  notify-send -u "$urgency" -a "focus-gate" "$summary" "$body" > /dev/null 2>&1 || true
}