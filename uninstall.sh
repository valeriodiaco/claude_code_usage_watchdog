#!/bin/bash
# Uninstalls claude_code_usage_watchdog LaunchAgent

PLIST_PATH="$HOME/Library/LaunchAgents/com.valeriodiaco.claude-watchdog.plist"

echo "Uninstalling claude_code_usage_watchdog..."
launchctl unload "$PLIST_PATH" 2>/dev/null || true
rm -f "$PLIST_PATH"
echo "Done. Watchdog stopped and LaunchAgent removed."
