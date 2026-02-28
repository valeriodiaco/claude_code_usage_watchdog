#!/bin/bash
# claude_code_usage_watchdog.sh v2.1
# Monitors Claude Code usage via API and kills automation processes when threshold is reached.
# Protects interactive quota by stopping background automation before limits are hit.
#
# Usage: ./claude_code_usage_watchdog.sh [options]
#   -t <percent>   Usage threshold to trigger kill (default: 90)
#   -i <seconds>   Check interval (default: 60)
#   -m <metric>    Metric to monitor: five_hour, seven_day, seven_day_sonnet (default: five_hour)
#   -w <percent>   Reserve this % of weekly quota per remaining day (default: 0 = disabled)
#                  Example: -w 6 reserves 6% per day. With 5 days left, kills at 70%.
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
WEEKLY_RESERVE_PER_DAY=0
WEEKLY_STOP_FLAG="/tmp/watchdog_weekly_exceeded"

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
        -w) WEEKLY_RESERVE_PER_DAY="$2"; shift 2 ;;
        --dry-run) DRY_RUN=true; shift ;;
        --once) ONCE=true; shift ;;
        -h|--help) usage ;;
        *) echo "Unknown option: $1"; usage ;;
    esac
done

OAUTH_CLIENT_ID="9d1c250a-e61b-44d9-88ed-5944d1962f5e"
KEYCHAIN_SERVICE="Claude Code-credentials"

read_keychain() {
    security find-generic-password -s "$KEYCHAIN_SERVICE" -w 2>/dev/null || return 1
}

write_keychain() {
    local new_json="$1"
    # Delete old entry and write new one
    security delete-generic-password -s "$KEYCHAIN_SERVICE" 2>/dev/null || true
    security add-generic-password -s "$KEYCHAIN_SERVICE" -w "$new_json" 2>/dev/null || return 1
}

get_token() {
    local raw
    raw=$(read_keychain) || return 1
    echo "$raw" | python3 -c "import sys,json; print(json.load(sys.stdin)['claudeAiOauth']['accessToken'])" 2>/dev/null || return 1
}

refresh_token() {
    local raw
    raw=$(read_keychain) || { log "ERROR: cannot read Keychain for refresh"; return 1; }

    local rt
    rt=$(echo "$raw" | python3 -c "import sys,json; print(json.load(sys.stdin)['claudeAiOauth']['refreshToken'])" 2>/dev/null) || return 1

    log "Refreshing OAuth token..."
    local resp
    resp=$(curl -s --max-time 15 -X POST "https://console.anthropic.com/api/oauth/token" \
        -H "Content-Type: application/json" \
        -d "{\"grant_type\":\"refresh_token\",\"refresh_token\":\"$rt\",\"client_id\":\"$OAUTH_CLIENT_ID\"}" 2>/dev/null)

    # Check for error
    if echo "$resp" | python3 -c "import sys,json; d=json.load(sys.stdin); exit(0 if 'access_token' in d else 1)" 2>/dev/null; then
        # Update Keychain with new tokens
        local new_json
        new_json=$(python3 -c "
import sys, json
raw = json.loads('''$raw''')
resp = json.loads('''$resp''')
raw['claudeAiOauth']['accessToken'] = resp['access_token']
if 'refresh_token' in resp:
    raw['claudeAiOauth']['refreshToken'] = resp['refresh_token']
if 'expires_in' in resp:
    import time
    raw['claudeAiOauth']['expiresAt'] = int((time.time() + resp['expires_in']) * 1000)
print(json.dumps(raw))
" 2>/dev/null) || { log "ERROR: failed to build new credentials JSON"; return 1; }

        write_keychain "$new_json" || { log "ERROR: failed to write to Keychain"; return 1; }
        log "Token refreshed and saved to Keychain"
        # Return new access token
        echo "$new_json" | python3 -c "import sys,json; print(json.load(sys.stdin)['claudeAiOauth']['accessToken'])" 2>/dev/null
        return 0
    else
        local err_msg
        err_msg=$(echo "$resp" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('error_description', d.get('error','unknown')))" 2>/dev/null || echo "unknown")
        log "ERROR: token refresh failed: $err_msg"
        return 1
    fi
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

calc_weekly_threshold() {
    local json="$1"
    local reserve="$2"
    echo "$json" | python3 -c "
import sys, json
from datetime import datetime, timezone

data = json.load(sys.stdin)
m = data.get('seven_day')
if not m or 'resets_at' not in m:
    print(-1)
    sys.exit()

resets = m['resets_at']
try:
    reset_dt = datetime.fromisoformat(resets.replace('Z', '+00:00'))
    now = datetime.now(timezone.utc)
    days_left = max(1, (reset_dt - now).days + 1)
    reserve = int($reserve)
    threshold = 100 - (days_left * reserve)
    threshold = max(10, min(95, threshold))
    print(threshold)
except:
    print(-1)
" 2>/dev/null || echo "-1"
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
log "  weekly rsv : $(if [[ $WEEKLY_RESERVE_PER_DAY -gt 0 ]]; then echo "${WEEKLY_RESERVE_PER_DAY}%/day"; else echo 'disabled'; fi)"
log "  interval   : ${INTERVAL}s"
log "  process    : $PROC_PATTERN"
log "  exclude    : ${EXCLUDE_PIDS:-none}"
log "  dry run    : $DRY_RUN"
log "  mode       : $(if $ONCE; then echo 'single check'; else echo 'continuous'; fi)"
log "========================================="

# Failsafe: after this many consecutive errors, kill automation as precaution
MAX_ERRORS=5
error_count=0

# Main loop
while true; do
    # Re-read token every cycle (Claude Code refreshes it in Keychain)
    TOKEN=$(get_token) || { 
        log "ERROR: cannot read token from Keychain"
        error_count=$((error_count + 1))
        if [[ "$error_count" -ge "$MAX_ERRORS" ]]; then
            log "FAILSAFE: $error_count consecutive errors, killing automation as precaution"
            kill_automation
            error_count=0
        fi
        sleep "$INTERVAL"
        continue
    }

    JSON=$(get_usage "$TOKEN")

    if [[ -z "$JSON" ]] || ! echo "$JSON" | python3 -c "import sys,json; json.load(sys.stdin)" &>/dev/null; then
        log "WARNING: API call failed or invalid JSON"
        error_count=$((error_count + 1))
        if [[ "$error_count" -ge "$MAX_ERRORS" ]]; then
            log "FAILSAFE: $error_count consecutive errors, killing automation as precaution"
            kill_automation
            error_count=0
        fi
        sleep "$INTERVAL"
        continue
    fi

    # Detect API errors (expired token, auth failures, etc.)
    if echo "$JSON" | python3 -c "import sys,json; d=json.load(sys.stdin); exit(0 if d.get('type')=='error' else 1)" 2>/dev/null; then
        local_err=$(echo "$JSON" | python3 -c "import sys,json; print(json.load(sys.stdin).get('error',{}).get('message','unknown'))" 2>/dev/null)
        log "WARNING: API error: $local_err"

        # Try to refresh token automatically
        NEW_TOKEN=$(refresh_token) 
        if [[ -n "$NEW_TOKEN" ]]; then
            JSON=$(get_usage "$NEW_TOKEN")
            # Check if refresh fixed it
            if echo "$JSON" | python3 -c "import sys,json; d=json.load(sys.stdin); exit(0 if d.get('type')=='error' else 1)" 2>/dev/null; then
                log "WARNING: API still failing after refresh"
                error_count=$((error_count + 1))
                if [[ "$error_count" -ge "$MAX_ERRORS" ]]; then
                    log "FAILSAFE: $error_count consecutive errors, killing automation as precaution"
                    kill_automation
                    error_count=0
                fi
                sleep "$INTERVAL"
                continue
            fi
            # Success - fall through to normal processing
            error_count=0
        else
            error_count=$((error_count + 1))
            if [[ "$error_count" -ge "$MAX_ERRORS" ]]; then
                log "FAILSAFE: $error_count consecutive errors, killing automation as precaution"
                kill_automation
                error_count=0
            fi
            sleep "$INTERVAL"
            continue
        fi
    fi

    # Reset error count on success
    error_count=0

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

    # Dynamic weekly threshold check
    if [[ "$WEEKLY_RESERVE_PER_DAY" -gt 0 ]]; then
        WEEKLY_UTIL=$(parse_utilization "$JSON" "seven_day")
        WEEKLY_RESETS=$(parse_resets_at "$JSON" "seven_day")
        WEEKLY_THRESH=$(calc_weekly_threshold "$JSON" "$WEEKLY_RESERVE_PER_DAY")
        if [[ "$WEEKLY_THRESH" != "-1" ]] && [[ "$WEEKLY_UTIL" != "-1" ]]; then
            if [[ "$WEEKLY_UTIL" -ge "$WEEKLY_THRESH" ]]; then
                log "ALERT: seven_day at ${WEEKLY_UTIL}% (dynamic threshold: ${WEEKLY_THRESH}%, reserve: ${WEEKLY_RESERVE_PER_DAY}%/day) - resets at $WEEKLY_RESETS"
                log "  Writing weekly stop flag: $WEEKLY_STOP_FLAG"
                echo "$(date '+%Y-%m-%d %H:%M:%S') seven_day=${WEEKLY_UTIL}% threshold=${WEEKLY_THRESH}% reserve=${WEEKLY_RESERVE_PER_DAY}%/day" > "$WEEKLY_STOP_FLAG"
                log "  Killing processes matching '$PROC_PATTERN'..."
                kill_automation
            else
                rm -f "$WEEKLY_STOP_FLAG" 2>/dev/null
                log "OK: seven_day at ${WEEKLY_UTIL}% (dynamic threshold: ${WEEKLY_THRESH}%, ${WEEKLY_RESERVE_PER_DAY}%/day)"
            fi
        fi
    fi

    if $ONCE; then
        exit 0
    fi

    sleep "$INTERVAL"
done
