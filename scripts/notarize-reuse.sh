#!/usr/bin/env bash
set -euo pipefail

# -----------------------------
# Config
# -----------------------------
MAX_WAIT_MINUTES=2   # how long to poll before exiting gracefully
POLL_INTERVAL=60      # seconds between polls
UUID_FILE=".notarization_uuid.json"
touch "$UUID_FILE"

# Required environment variables:
# APPLE_ID
# APPLE_TEAM_ID
# APPLE_APP_SPECIFIC_PASSWORD
# DMG_PATH (path to your DMG or ZIP for notarization)
# -----------------------------

# Helper to get current timestamp in seconds
now() {
    date +%s
}

# Load cached UUID if exists
UUID=""
if [ -f "$UUID_FILE" ]; then
    UUID=$(jq -r '.uuid' "$UUID_FILE")
    if [ -n "$UUID" ] && [ "$UUID" != "null" ]; then
        echo "🔄 Reusing cached notarization UUID: $UUID"
    else
        UUID=""
    fi
fi

# If no cached UUID, submit for notarization
if [ -z "$UUID" ]; then
    echo "🚀 Submitting $DMG_PATH for notarization..."
    SUBMIT_OUTPUT=$(xcrun notarytool submit "$DMG_PATH" \
        --apple-id "$APPLE_ID" \
        --team-id "$APPLE_TEAM_ID" \
        --password "$APPLE_APP_SPECIFIC_PASSWORD" \
        --output-format json)
    
    echo "$SUBMIT_OUTPUT" > submit-output.json
    UUID=$(jq -r '.id' submit-output.json)

    if [ -z "$UUID" ] || [ "$UUID" = "null" ]; then
        echo "❌ Failed to get UUID from notarization submission."
        exit 1
    fi

    echo "{\"uuid\": \"$UUID\"}" > "$UUID_FILE"
    echo "🆕 New notarization UUID: $UUID"
fi

# Poll notarization status
START_TIME=$(now)
while :; do
    INFO_JSON=$(xcrun notarytool info "$UUID" \
        --apple-id "$APPLE_ID" \
        --team-id "$APPLE_TEAM_ID" \
        --password "$APPLE_APP_SPECIFIC_PASSWORD" \
        --output-format json || true)

    STATUS=$(echo "$INFO_JSON" | jq -r '.status')
    echo "⏳ Status: $STATUS"

    case "$STATUS" in
        Accepted)
            echo "✅ Notarization complete. Fetching log..."
            echo "$INFO_JSON" > notarization-log.json
            cat notarization-log.json
            rm -f "$UUID_FILE" # clear cache so we don't reuse an old UUID
            exit 0
            ;;
        Invalid)
            echo "❌ Notarization failed. Fetching log..."
            echo "$INFO_JSON" > notarization-log.json
            cat notarization-log.json
            exit 1
            ;;
        In\ Progress)
            # Continue polling
            ;;
        *)
            echo "⚠️ Unknown status: $STATUS"
            ;;
    esac

    # Timeout check
    ELAPSED_MIN=$(( ( $(now) - START_TIME ) / 60 ))
    if [ "$ELAPSED_MIN" -ge "$MAX_WAIT_MINUTES" ]; then
        echo "⏳ Timeout reached ($MAX_WAIT_MINUTES min). Saving UUID for next run."
        exit 0
    fi

    sleep "$POLL_INTERVAL"
done
