#!/usr/bin/env bash
set -euo pipefail

GUI="http://127.0.0.1:8384"

echo "======================================"
echo " Syncthing SECONDARY / JOIN Setup"
echo "======================================"

install_packages() {
    if command -v apt >/dev/null 2>&1; then
        sudo apt update
        sudo apt install -y syncthing jq curl
    elif command -v dnf >/dev/null 2>&1; then
        sudo dnf install -y syncthing jq curl
    elif command -v pacman >/dev/null 2>&1; then
        sudo pacman -S --needed syncthing jq curl
    else
        echo "Unsupported package manager."
        echo "Install syncthing, jq, and curl manually, then rerun."
        exit 1
    fi
}

for CMD in syncthing jq curl; do
    if ! command -v "$CMD" >/dev/null 2>&1; then
        echo "Required packages are missing."
        install_packages
        break
    fi
done

echo
echo "Starting Syncthing..."
systemctl --user enable --now syncthing.service

echo "Waiting for Syncthing API..."
until curl -sf "$GUI/rest/noauth/health" >/dev/null 2>&1; do
    sleep 2
done

CONFIG="$HOME/.local/state/syncthing/config.xml"
[[ -f "$CONFIG" ]] || CONFIG="$HOME/.config/syncthing/config.xml"

if [[ ! -f "$CONFIG" ]]; then
    echo "Could not locate Syncthing config.xml."
    exit 1
fi

API_KEY=$(sed -n 's:.*<apikey>\(.*\)</apikey>.*:\1:p' "$CONFIG" | head -1)

if [[ -z "$API_KEY" ]]; then
    echo "Could not determine Syncthing API key."
    exit 1
fi

api() {
    curl -sf -H "X-API-Key: $API_KEY" "$@"
}

LOCAL_ID=$(api "$GUI/rest/system/status" | jq -r '.myID')

echo
echo "This device:"
echo "--------------------------------------"
echo "$LOCAL_ID"
echo "--------------------------------------"

echo
read -r -p "Paste PRIMARY Device ID: " PRIMARY_ID
PRIMARY_ID="${PRIMARY_ID//[[:space:]]/}"

if [[ -z "$PRIMARY_ID" ]]; then
    echo "Primary Device ID is required."
    exit 1
fi

EXISTING=$(api "$GUI/rest/config/devices" |
    jq -r --arg id "$PRIMARY_ID" '.[] | select(.deviceID==$id) | .deviceID')

if [[ "$EXISTING" == "$PRIMARY_ID" ]]; then
    echo
    echo "Primary device is already configured."
else
    echo
    echo "Adding primary device..."

    DEVICE_TEMPLATE=$(api "$GUI/rest/config/defaults/device")
    DEVICE_JSON=$(jq         --arg id "$PRIMARY_ID"         '
        .deviceID=$id |
        .name="Syncthing Primary"
        ' <<< "$DEVICE_TEMPLATE")

    api         -X POST         -H "Content-Type: application/json"         -d "$DEVICE_JSON"         "$GUI/rest/config/devices" >/dev/null

    echo "Primary device added."
fi

echo
echo "Waiting for the primary machine to accept this device..."
echo

while true; do
    CONNECTIONS=$(api "$GUI/rest/system/connections" || echo '{}')
    CONNECTED=$(jq -r         --arg id "$PRIMARY_ID"         '.connections[$id].connected // false'         <<< "$CONNECTIONS")

    if [[ "$CONNECTED" == "true" ]]; then
        break
    fi

    sleep 3
done

echo "Primary connected."
echo
echo "Waiting for folder offers from primary..."

while true; do
    PENDING=$(api "$GUI/rest/cluster/pending/folders?device=$PRIMARY_ID" || echo '{}')
    OFFER_COUNT=$(jq 'length' <<< "$PENDING")

    if (( OFFER_COUNT > 0 )); then
        break
    fi

    sleep 3
done

echo
echo "Primary offered $OFFER_COUNT folder(s)."
echo

declare -a ACCEPTED_FOLDERS=()

PENDING=$(api "$GUI/rest/cluster/pending/folders?device=$PRIMARY_ID" || echo '{}')
mapfile -t FOLDER_IDS < <(jq -r 'keys[]' <<< "$PENDING")

for FOLDER_ID in "${FOLDER_IDS[@]}"; do
    CURRENT_PENDING=$(api "$GUI/rest/cluster/pending/folders?device=$PRIMARY_ID" || echo '{}')

    if ! jq -e --arg id "$FOLDER_ID" 'has($id)' <<< "$CURRENT_PENDING" >/dev/null; then
        continue
    fi

    FOLDER_LABEL=$(jq -r         --arg folder "$FOLDER_ID"         --arg device "$PRIMARY_ID"         '.[$folder].offeredBy[$device].label // $folder'         <<< "$CURRENT_PENDING")

    echo
    echo "======================================"
    echo " FOLDER OFFER"
    echo "======================================"
    echo
    echo "Name: $FOLDER_LABEL"
    echo "ID:   $FOLDER_ID"
    echo

    DEFAULT_PATH="$HOME/$FOLDER_LABEL"
    read -r -p "Local path [$DEFAULT_PATH]: " LOCAL_PATH
    LOCAL_PATH="${LOCAL_PATH:-$DEFAULT_PATH}"
    LOCAL_PATH="${LOCAL_PATH/#\~/$HOME}"

    if [[ "$LOCAL_PATH" != "/" ]]; then
        LOCAL_PATH="${LOCAL_PATH%/}"
    fi

    if [[ -d "$LOCAL_PATH" ]] &&
       [[ -n "$(find "$LOCAL_PATH" -mindepth 1 -maxdepth 1 -print -quit 2>/dev/null)" ]]; then

        echo
        echo "Files already exist in:"
        echo
        echo "  $LOCAL_PATH"
        echo
        echo "Choose how this folder should join:"
        echo
        echo "  1) MERGE"
        echo "     Keep local files and synchronize both sides."
        echo
        echo "  2) REPLACE LOCAL"
        echo "     Back up the existing local folder first,"
        echo "     then receive the primary copy."
        echo
        echo "  3) SKIP THIS FOLDER"
        echo

        read -r -p "Choice [1]: " CHOICE
        CHOICE="${CHOICE:-1}"

        case "$CHOICE" in
            1)
                echo
                echo "Merge selected."
                ;;
            2)
                TIMESTAMP=$(date '+%Y-%m-%d_%H-%M-%S')
                BACKUP="${LOCAL_PATH}.pre-syncthing-backup-${TIMESTAMP}"

                echo
                echo "Backing up existing folder:"
                echo
                echo "  $BACKUP"
                echo

                mv "$LOCAL_PATH" "$BACKUP"
                mkdir -p "$LOCAL_PATH"

                echo "Backup complete."
                ;;
            3)
                echo
                echo "Skipping $FOLDER_LABEL."
                continue
                ;;
            *)
                echo
                echo "Invalid selection."
                echo "Skipping $FOLDER_LABEL."
                continue
                ;;
        esac
    else
        mkdir -p "$LOCAL_PATH"
    fi

    echo
    echo "Accepting $FOLDER_LABEL..."

    FOLDER_TEMPLATE=$(api "$GUI/rest/config/defaults/folder")
    FOLDER_JSON=$(jq         --arg id "$FOLDER_ID"         --arg label "$FOLDER_LABEL"         --arg path "$LOCAL_PATH"         --arg local "$LOCAL_ID"         --arg primary "$PRIMARY_ID"         '
        .id=$id |
        .label=$label |
        .path=$path |
        .type="sendreceive" |
        .devices=[
            {"deviceID":$local},
            {"deviceID":$primary}
        ]
        ' <<< "$FOLDER_TEMPLATE")

    api         -X POST         -H "Content-Type: application/json"         -d "$FOLDER_JSON"         "$GUI/rest/config/folders" >/dev/null

    ACCEPTED_FOLDERS+=("$FOLDER_ID|$FOLDER_LABEL|$LOCAL_PATH")
    echo "Accepted."
done

if [[ ${#ACCEPTED_FOLDERS[@]} -eq 0 ]]; then
    echo
    echo "No folders were accepted."
    echo
    echo "Syncthing is installed and automatic startup is enabled."
    exit 0
fi

echo
echo "======================================"
echo " INITIAL SYNCHRONIZATION"
echo "======================================"
echo

for ENTRY in "${ACCEPTED_FOLDERS[@]}"; do
    IFS='|' read -r FOLDER_ID FOLDER_LABEL LOCAL_PATH <<< "$ENTRY"

    echo
    echo "Synchronizing:"
    echo "  $FOLDER_LABEL"
    echo "  $LOCAL_PATH"

    while true; do
        COMPLETION=$(api             "$GUI/rest/db/completion?device=$PRIMARY_ID&folder=$FOLDER_ID"             2>/dev/null || echo '{}')

        PERCENT=$(jq -r '.completion // 0' <<< "$COMPLETION")
        printf "\rCompletion: %s%%   " "$PERCENT"

        if awk "BEGIN {exit !($PERCENT >= 100)}"; then
            break
        fi

        sleep 3
    done

    echo
    echo "Complete."
done

echo
echo
echo "======================================"
echo " SYNCTHING JOIN COMPLETE"
echo "======================================"
echo
echo "Primary:"
echo "  $PRIMARY_ID"
echo
echo "Folders configured:"

for ENTRY in "${ACCEPTED_FOLDERS[@]}"; do
    IFS='|' read -r FOLDER_ID FOLDER_LABEL LOCAL_PATH <<< "$ENTRY"
    echo
    echo "  $FOLDER_LABEL"
    echo "    $LOCAL_PATH"
done

echo
echo "Automatic startup: ENABLED"
echo
echo "This secondary device is ready."
