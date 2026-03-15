#!/bin/bash
# Runs kobo sync when Kobo is mounted
# Called by launchd (macOS) or systemd (Linux)
# Placeholders replaced at install time.

KOBO_SYNC_DIR="{{KOBO_SYNC_DIR}}"
KOBO_DB="{{KOBO_DB}}"
LOG_FILE="{{LOG_FILE_PATH}}"

mkdir -p "$(dirname "$LOG_FILE")"

echo "$(date): Script triggered" >> "$LOG_FILE"

# Wait for Kobo to be fully mounted (up to 10 seconds)
TIMEOUT=10
WAITED=0
while [[ ! -f "$KOBO_DB" ]] && [[ $WAITED -lt $TIMEOUT ]]; do
  sleep 1
  WAITED=$((WAITED + 1))
done

# Only proceed if Kobo is actually mounted
if [[ ! -f "$KOBO_DB" ]]; then
  echo "$(date): Kobo DB not found after ${WAITED}s, exiting (unmount or timeout)" >> "$LOG_FILE"
  exit 0
fi

echo "$(date): Kobo DB found after ${WAITED}s, starting sync..." >> "$LOG_FILE"

# Source shell profile to get mise/rbenv/etc
export PATH="$HOME/.local/bin:$HOME/bin:/opt/homebrew/bin:/usr/local/bin:$PATH"

cd "$KOBO_SYNC_DIR"

# Use mise exec if available, otherwise try direct bundle
if command -v mise &> /dev/null; then
  BUNDLE_CMD="mise exec -- bundle"
else
  BUNDLE_CMD="bundle"
fi

notify() {
  local msg="$1"
  local is_error="${2:-false}"
  if command -v osascript &>/dev/null; then
    if [[ "$is_error" == "true" ]]; then
      osascript -e "display notification \"$msg\" with title \"Kobo Sync\" sound name \"Basso\"" 2>/dev/null || true
    else
      osascript -e "display notification \"$msg\" with title \"Kobo Sync\"" 2>/dev/null || true
    fi
  elif command -v notify-send &>/dev/null; then
    if [[ "$is_error" == "true" ]]; then
      notify-send -u critical "Kobo Sync" "$msg" 2>/dev/null || true
    else
      notify-send "Kobo Sync" "$msg" 2>/dev/null || true
    fi
  fi
}

# Pass KOBO_VOLUME to rake so resolve_kobo_volume picks up the right path
if KOBO_VOLUME="${KOBO_DB%/.kobo/KoboReader.sqlite}" $BUNDLE_CMD exec rake sync:run >> "$LOG_FILE" 2>&1; then
  notify "Reading sessions synced to BookLore"
  echo "$(date): Sync completed successfully" >> "$LOG_FILE"
else
  notify "Sync failed - check $LOG_FILE" true
  echo "$(date): Sync failed" >> "$LOG_FILE"
fi