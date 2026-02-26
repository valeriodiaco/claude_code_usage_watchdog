#!/bin/bash
# claude_code_usage_watchdog.sh v2.0
# Monitors Claude Code usage via API and kills automation processes when threshold is reached.
# Protects interactive quota by stopping background automation before limits are hit.
#
# Usage: ./claude_code_usage_watchdog.sh [options]
#   -t <percent>   Usage threshold to trigger kill (default: 90)
#   -i <seconds>   Check interval (default: 60)
#   -m <metric>    Metric to monitor: five_hour, seven_day, seven_day_sonnet (default: five_hour)
#   -p <pattern>   Process name pattern to kill (default: claude)
#   -e <pids>      Comma-separated PIDs to exclude from kill (e.g., sensor PID)
#   --dry-run      Log actions without killing anything
#   --once         Check once and exit (useful for cron)
#   -h, --help     Show this help
#
# Examples:
#   ./claude_code_usage_watchdog.sh --dry-run -i 30
#   ./claude_code_usage_watchdog.sh -t 85 -m five_hour
#   ./claude_code_usage_watchdog.sh --once
#   ./claude_code_usage_watchdog.sh -e 12345,67890

set -euo pipefail

# Defaults
THRESHOLD=90
INTERVAL=60
METRIC="five_hour"
PROC_PATTERN="claude"
EXCLUDE_PIDS=""
DRY_RUN=false
ONCE=false
LOG_FILE=""

log() {
    local msg="[$(date '+%Y-%m-%d %H:%M:%S')] $1"
    echo "$msg"
    if [[ -n "$LOG_FILE" ]]; then
        echo "$msg" >> "$LOG_FILE"
    fi
}

usage() {
    sed -n '2,/^$/s/^# //p' "$0"
    exit 0
}

# Parse args
while [[ $# -gt 0 ]]; do
    case "$1" in
        -t) THRESHOLD="$2"; shift 2 ;;
        -i) INTERVAL="$2"; shift 2 ;;
        -m) METRIC="$2"; shift 2 ;;
        -p) PROC_PATTERN="$2"; shift 2 ;;
        -e) EXCLUDE_PIDS="$2"; shift 2 ;;
        -l) LOG_FILE="$2"; shift 2 ;;
        --dry-run) DRY_RUN=true; shift ;;
        --once) ONCE=true; shift ;;
        -h|--help) usage ;;
        *) echo "Unknown option: $1"; usage ;;
    esac
done

get_token() {
    local raw
    raw=$(security find-generic-password -s "Claude Code-credentials" -w 2>/dev/null) || return 1
    echo "$raw" | python3 -c "import sys,json; print(json.load(sys.stdin)['claudeAiOauth']['accessToken'])" 2>/dev/null || return 1
}

get_usage() {
    local token="$1"
    curl -s --max-time 10 "https://api.anthropic.com/api/oauth/usage" \
        -H "Authorization: Bearer $token" \
        -H "anthropic-beta: oauth-2025-04-20" \
        -H "User-Agent: claude-code/2.1.59" 2>/dev/null
}

parse_utilization() {
    local json="$1"
    local metric="$2"
    echo "$json" | python3 -c "
import sys, json
data = json.load(sys.stdin)
m = data.get('$metric')
if m and 'utilization' in m:
    print(int(m['utilization']))
else:
    print(-1)
" 2>/dev/null || echo "-1"
}

parse_resets_at() {
    local json="$1"
    local metric="$2"
    echo "$json" | python3 -c "
import sys, json
data = json.load(sys.stdin)
m = data.get('$metric')
if m and 'resets_at' in m:
    print(m['resets_at'])
else:
    print('unknown')
" 2>/dev/null || echo "unknown"
}

kill_automation() {
    local exclude_pattern=""
    if [[ -n "$EXCLUDE_PIDS" ]]; then
        for pid in ${EXCLUDE_PIDS//,/ }; do
            exclude_pattern="$exclude_pattern|$pid"
        done
        exclude_pattern="${exclude_pattern:1}"  # remove leading |
    fi

    # Also exclude our own PID and parent
    local my_pid=$$
    local my_ppid=$PPID

    local killed=0
    while IFS= read -r line; do
        local pid
        pid=$(echo "$line" | awk '{print $1}')
        pid=$(echo "$pid" | tr -d ' ')

        # Skip our own process tree
        [[ "$pid" == "$my_pid" ]] && continue
        [[ "$pid" == "$my_ppid" ]] && continue

        # Skip the watchdog itself (pattern matches script name)
        local cmd
        cmd=$(echo "$line" | awk '{$1=""; print}')
        if echo "$cmd" | grep -q "usage_watchdog"; then
            log "  SKIP: PID $pid (watchdog)"
            continue
        fi

        # Skip excluded PIDs
        if [[ -n "$exclude_pattern" ]] && echo "$pid" | grep -qE "^($exclude_pattern)$"; then
            log "  SKIP: PID $pid (excluded)"
            continue
        fi

        if $DRY_RUN; then
            log "  DRY RUN: would kill PID $pid ($cmd)"
        else
            kill "$pid" 2>/dev/null && log "  KILLED: PID $pid ($cmd)" || log "  FAILED to kill PID $pid"
        fi
        killed=$((killed + 1))
    done < <(pgrep -f "$PROC_PATTERN" | while read -r p; do
        ps -p "$p" -o pid=,command= 2>/dev/null
    done)

    log "  Total processes targeted: $killed"
}

# Startup
log "========================================="
log "claude_code_usage_watchdog v2.0 started"
log "  metric     : $METRIC"
log "  threshold  : ${THRESHOLD}%"
log "  interval   : ${INTERVAL}s"
log "  process    : $PROC_PATTERN"
log "  exclude    : ${EXCLUDE_PIDS:-none}"
log "  dry run    : $DRY_RUN"
log "  mode       : $(if $ONCE; then echo 'single check'; else echo 'continuous'; fi)"
log "========================================="

# Get token once at startup
TOKEN=$(get_token) || { log "ERROR: cannot read token from Keychain"; exit 1; }
log "Token retrieved from Keychain"

# Main loop
while true; do
    JSON=$(get_usage "$TOKEN")

    if [[ -z "$JSON" ]] || ! echo "$JSON" | python3 -c "import sys,json; json.load(sys.stdin)" &>/dev/null; then
        log "WARNING: API call failed or invalid JSON, retrying token..."
        TOKEN=$(get_token) || { log "ERROR: cannot refresh token"; sleep "$INTERVAL"; continue; }
        JSON=$(get_usage "$TOKEN")
    fi

    UTIL=$(parse_utilization "$JSON" "$METRIC")
    RESETS=$(parse_resets_at "$JSON" "$METRIC")

    if [[ "$UTIL" == "-1" ]]; then
        log "WARNING: metric '$METRIC' not found or null in response"
        # Show available metrics
        log "  Available: $(echo "$JSON" | python3 -c "
import sys, json
data = json.load(sys.stdin)
avail = [k for k,v in data.items() if isinstance(v, dict) and 'utilization' in v]
print(', '.join(avail))
" 2>/dev/null || echo 'unknown')"
    elif [[ "$UTIL" -ge "$THRESHOLD" ]]; then
        log "ALERT: $METRIC at ${UTIL}% (threshold: ${THRESHOLD}%) - resets at $RESETS"
        log "  Killing processes matching '$PROC_PATTERN'..."
        kill_automation
    else
        log "OK: $METRIC at ${UTIL}% (threshold: ${THRESHOLD}%) - resets at $RESETS"
    fi

    if $ONCE; then
        exit 0
    fi

    sleep "$INTERVAL"
done
