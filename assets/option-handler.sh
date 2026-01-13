#!/bin/bash
# Option button handler for short/long press detection
# Short press (<0.5s): Toggle repeat
# Long press (>0.5s): Toggle shuffle

LOCKFILE="/tmp/option_press.lock"
LONG_PRESS_FILE="/tmp/option_long_press"

case "$1" in
    short)
        # Called immediately on button press
        # Schedule short action, will be cancelled if long press detected
        rm -f "$LONG_PRESS_FILE"
        echo $$ > "$LOCKFILE"
        sleep 0.5
        # Check if we're still the active handler (not superseded by long press)
        if [ ! -f "$LONG_PRESS_FILE" ] && [ -f "$LOCKFILE" ]; then
            LOCK_PID=$(cat "$LOCKFILE" 2>/dev/null)
            if [ "$LOCK_PID" = "$$" ]; then
                /usr/local/bin/volumio repeat
                rm -f "$LOCKFILE"
            fi
        fi
        ;;
    long)
        # Called after delay (button held)
        touch "$LONG_PRESS_FILE"
        rm -f "$LOCKFILE"
        /usr/local/bin/volumio random
        ;;
    *)
        echo "Usage: $0 {short|long}"
        exit 1
        ;;
esac
