# claude_code_usage_watchdog

Monitors Claude Code usage via the Anthropic API and kills automation processes when a threshold is reached. Protects your interactive quota by stopping background automation before limits are hit.

## How it works

1. Reads the OAuth token from macOS Keychain (`Claude Code-credentials`)
2. Calls `GET https://api.anthropic.com/api/oauth/usage` to get live utilization percentages
3. If the chosen metric exceeds the threshold, kills processes matching a pattern
4. Repeats every N seconds

No tmux, no screen scraping, no timing hacks. Just a direct API call.

## Available metrics

| Metric | Description |
|--------|-------------|
| `five_hour` | Current 5-hour session window (default) |
| `seven_day` | Weekly usage across all models |
| `seven_day_sonnet` | Weekly Sonnet-only usage |
| `extra_usage` | Extra usage credits |

## Install (auto-start at login)

```bash
git clone https://github.com/valeriodiaco/claude_code_usage_watchdog.git
cd claude_code_usage_watchdog
chmod +x install.sh uninstall.sh claude_code_usage_watchdog.sh
./install.sh          # default: 85% threshold, 60s interval
./install.sh 90 120   # custom: 90% threshold, 120s interval
```

This installs a macOS LaunchAgent that starts automatically at login and restarts if it crashes.

```bash
# Check status
launchctl list | grep watchdog
tail -f /tmp/watchdog.log

# Stop / uninstall
./uninstall.sh
```

## Quick start (manual)

```bash
# Check once, dry run
./claude_code_usage_watchdog.sh --once --dry-run

# Monitor continuously, kill at 90%
./claude_code_usage_watchdog.sh -t 90 -i 60

# Monitor with specific exclusions (e.g., protect a specific PID)
./claude_code_usage_watchdog.sh -t 85 -e 12345

# Log to file
./claude_code_usage_watchdog.sh -l /tmp/watchdog.log
```

## Options

```
-t <percent>   Usage threshold to trigger kill (default: 90)
-i <seconds>   Check interval (default: 60)
-m <metric>    Metric to monitor (default: five_hour)
-w <percent>   Reserve this % of weekly quota per remaining day (default: 0 = disabled)
-p <pattern>   Process name pattern to kill (default: claude)
-e <pids>      Comma-separated PIDs to exclude from kill
-l <file>      Also log to file
--dry-run      Log actions without killing anything
--once         Check once and exit (good for cron)
-h, --help     Show help
```

## Dynamic weekly threshold (`-w`)

The `-w` flag enables a dynamic threshold on the `seven_day` metric that adjusts based on how many days remain before the weekly reset. This prevents burning through your entire weekly quota early in the week.

**How it works:** `-w 6` means "reserve 6% of weekly quota per remaining day." The dynamic threshold is calculated as:

```
threshold = 100 - (days_left * reserve_per_day)
```

| Days left | Threshold (`-w 6`) | Meaning |
|-----------|-------------------|---------|
| 7 | 58% | Week just started, be conservative |
| 5 | 70% | Mid-week |
| 3 | 82% | Getting closer to reset |
| 1 | 94% | Resets tomorrow, use almost everything |

When the weekly usage exceeds the dynamic threshold, the watchdog:
1. Kills automation processes (same as the static `-t` threshold)
2. Writes a stop flag to `/tmp/watchdog_weekly_exceeded`

The stop flag can be used by external scripts (e.g., overnight runners) to halt completely instead of waiting for quota to recover.

```bash
# Static 85% on five_hour + dynamic 6%/day on seven_day
./claude_code_usage_watchdog.sh -t 85 -w 6

# Check the stop flag from another script
if [ -f /tmp/watchdog_weekly_exceeded ]; then
    echo "Weekly limit hit, stopping."
    exit 0
fi
```

## Use case

You run automated pipelines (RALPH loops, thread assembly, etc.) using Claude Code in background sessions. These consume the same 5-hour quota as your interactive sessions. The watchdog monitors usage and kills automation processes before they exhaust your quota, preserving capacity for interactive work.

## Requirements

- macOS (uses `security` command for Keychain access)
- python3 (for JSON parsing)
- curl
- Claude Code authenticated via OAuth (not API key)

## How the API works

Claude Code stores OAuth credentials in macOS Keychain under `"Claude Code-credentials"`. The token is used to call:

```
GET https://api.anthropic.com/api/oauth/usage
Authorization: Bearer <token>
anthropic-beta: oauth-2025-04-20
```

Response:
```json
{
  "five_hour": {
    "utilization": 15.0,
    "resets_at": "2026-02-26T23:00:00.203355+00:00"
  },
  "seven_day": {
    "utilization": 28.0,
    "resets_at": "2026-03-04T22:00:00.203379+00:00"
  }
}
```

`utilization` is the percentage used (0-100).

## License

MIT
