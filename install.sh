#!/bin/bash
# Installs claude_code_usage_watchdog as a macOS LaunchAgent (auto-start at login)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PLIST_NAME="com.valeriodiaco.claude-watchdog"
PLIST_PATH="$HOME/Library/LaunchAgents/${PLIST_NAME}.plist"
THRESHOLD="${1:-85}"
INTERVAL="${2:-60}"
LOG_FILE="/tmp/watchdog.log"

echo "Installing claude_code_usage_watchdog as LaunchAgent..."
echo "  Script:    $SCRIPT_DIR/claude_code_usage_watchdog.sh"
echo "  Threshold: ${THRESHOLD}%"
echo "  Interval:  ${INTERVAL}s"
echo "  Log:       $LOG_FILE"

# Unload if already running
launchctl unload "$PLIST_PATH" 2>/dev/null || true

cat > "$PLIST_PATH" << PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>${PLIST_NAME}</string>
    <key>ProgramArguments</key>
    <array>
        <string>${SCRIPT_DIR}/claude_code_usage_watchdog.sh</string>
        <string>-t</string>
        <string>${THRESHOLD}</string>
        <string>-i</string>
        <string>${INTERVAL}</string>
        <string>-l</string>
        <string>${LOG_FILE}</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <true/>
    <key>StandardOutPath</key>
    <string>/tmp/watchdog_stdout.log</string>
    <key>StandardErrorPath</key>
    <string>/tmp/watchdog_stderr.log</string>
</dict>
</plist>
PLIST

launchctl load "$PLIST_PATH"

echo ""
echo "Done. Watchdog is running and will auto-start at login."
echo ""
echo "Commands:"
echo "  Status:    launchctl list | grep watchdog"
echo "  Log:       tail -f /tmp/watchdog.log"
echo "  Stop:      launchctl unload $PLIST_PATH"
echo "  Uninstall: ./uninstall.sh"
