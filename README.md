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

## Quick start

```bash
# Check once, dry run
./claude_code_usage_watchdog.sh --once --dry-run

# Monitor continuously, kill at 90%
./claude_code_usage_watchdog.sh -t 90 -i 60

# Monitor with specific exclusions (e.g., protect a sensor PID)
./claude_code_usage_watchdog.sh -t 85 -e 12345

# Log to file
./claude_code_usage_watchdog.sh -l /tmp/watchdog.log
```

## Options

```
-t <percent>   Usage threshold to trigger kill (default: 90)
-i <seconds>   Check interval (default: 60)
-m <metric>    Metric to monitor (default: five_hour)
-p <pattern>   Process name pattern to kill (default: claude)
-e <pids>      Comma-separated PIDs to exclude from kill
-l <file>      Also log to file
--dry-run      Log actions without killing anything
--once         Check once and exit (good for cron)
-h, --help     Show help
```

## Use case

You run automated pipelines (long-running pipelines, batch jobs, etc.) using Claude Code in background sessions. These consume the same 5-hour quota as your interactive sessions. The watchdog monitors usage and kills automation processes before they exhaust your quota, preserving capacity for interactive work.

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
