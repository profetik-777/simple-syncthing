#!/usr/bin/env bash
set -euo pipefail

GUI="http://127.0.0.1:8384"

echo "======================================"
echo " Syncthing PRIMARY Setup"
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

DEVICE_ID=$(api "$GUI/rest/system/status" | jq -r '.myID')

echo
echo "PRIMARY DEVICE ID"
echo "--------------------------------------"
echo "$DEVICE_ID"
echo "--------------------------------------"
echo
echo "You will enter this ID on each secondary device."

echo
echo "Enter folders to synchronize."
echo "Paste ONE folder path per line."
echo "Press ENTER on an empty line when finished."
echo
echo "Examples:"
echo "  $HOME/Desktop"
echo "  $HOME/Documents"
echo "  $HOME/Projects"
echo

declare -a SYNC_PATHS=()

while true; do
    read -r -p "Folder: " INPUT_PATH
    [[ -z "$INPUT_PATH" ]] && break

    INPUT_PATH="${INPUT_PATH/#\~/$HOME}"
    [[ "$INPUT_PATH" != "/" ]] && INPUT_PATH="${INPUT_PATH%/}"

    DUPLICATE=false
    for EXISTING in "${SYNC_PATHS[@]:-}"; do
        if [[ "$EXISTING" == "$INPUT_PATH" ]]; then
            DUPLICATE=true
            break
        fi
    done

    if [[ "$DUPLICATE" == true ]]; then
        echo "Already selected. Skipping."
        continue
    fi

    if [[ ! -d "$INPUT_PATH" ]]; then
        echo
        echo "Folder does not exist:"
        echo "  $INPUT_PATH"
        read -r -p "Create it? [y/N]: " CREATE
        if [[ "$CREATE" =~ ^[Yy]$ ]]; then
            mkdir -p "$INPUT_PATH"
        else
            echo "Skipped."
            continue
        fi
    fi

    SYNC_PATHS+=("$INPUT_PATH")
    echo "Added."
done

if [[ ${#SYNC_PATHS[@]} -eq 0 ]]; then
    echo
    echo "No folders selected. Nothing to configure."
    exit 1
fi

echo
echo "Folders selected:"
echo
for i in "${!SYNC_PATHS[@]}"; do
    printf "  %d. %s\n" "$((i + 1))" "${SYNC_PATHS[$i]}"
done

echo
read -r -p "Continue? [Y/n]: " CONFIRM
CONFIRM="${CONFIRM:-Y}"

if [[ ! "$CONFIRM" =~ ^[Yy]$ ]]; then
    echo "Setup cancelled."
    exit 0
fi

declare -a FOLDER_IDS=()

for SYNC_PATH in "${SYNC_PATHS[@]}"; do
    FOLDER_LABEL=$(basename "$SYNC_PATH")
    BASE_ID=$(echo "$FOLDER_LABEL" | tr '[:upper:]' '[:lower:]' | tr -cs 'a-z0-9' '-')
    BASE_ID="${BASE_ID%-}"
    FOLDER_ID="$BASE_ID"
    COUNTER=2

    while [[ " ${FOLDER_IDS[*]} " == *" $FOLDER_ID "* ]]; do
        FOLDER_ID="${BASE_ID}-${COUNTER}"
        ((COUNTER++))
    done

    FOLDER_IDS+=("$FOLDER_ID")

    echo
    echo "Creating Syncthing folder:"
    echo "  Label: $FOLDER_LABEL"
    echo "  Path:  $SYNC_PATH"
    echo "  ID:    $FOLDER_ID"

    FOLDER=$(api "$GUI/rest/config/defaults/folder")
    FOLDER=$(jq         --arg id "$FOLDER_ID"         --arg label "$FOLDER_LABEL"         --arg path "$SYNC_PATH"         --arg device "$DEVICE_ID"         '
        .id=$id |
        .label=$label |
        .path=$path |
        .type="sendreceive" |
        .devices=[{"deviceID":$device}]
        ' <<< "$FOLDER")

    api         -X POST         -H "Content-Type: application/json"         -d "$FOLDER"         "$GUI/rest/config/folders" >/dev/null
done

echo
echo "All folders configured."
echo
echo "======================================"
echo " WAITING FOR SECONDARY DEVICE"
echo "======================================"
echo
echo "Run syncthing-join.sh on the other machine."
echo
echo "Primary Device ID:"
echo "$DEVICE_ID"
echo

while true; do
    PENDING=$(api "$GUI/rest/cluster/pending/devices" || echo '{}')
    NEW_DEVICE=$(jq -r 'keys[0] // empty' <<< "$PENDING")

    if [[ -n "$NEW_DEVICE" ]]; then
        echo
        echo "Secondary device detected:"
        echo "$NEW_DEVICE"
        echo

        read -rp "Accept this device? [Y/n]: " ANSWER
        ANSWER="${ANSWER:-Y}"

        if [[ ! "$ANSWER" =~ ^[Yy]$ ]]; then
            echo "Device not accepted."
            sleep 5
            continue
        fi

        DEVICE_TEMPLATE=$(api "$GUI/rest/config/defaults/device")
        DEVICE_JSON=$(jq             --arg id "$NEW_DEVICE"             '
            .deviceID=$id |
            .name="Syncthing Secondary"
            ' <<< "$DEVICE_TEMPLATE")

        api             -X POST             -H "Content-Type: application/json"             -d "$DEVICE_JSON"             "$GUI/rest/config/devices" >/dev/null

        for FOLDER_ID in "${FOLDER_IDS[@]}"; do
            CURRENT_FOLDER=$(api "$GUI/rest/config/folders/$FOLDER_ID")
            UPDATED_FOLDER=$(jq                 --arg id "$NEW_DEVICE"                 '
                if (.devices | map(.deviceID) | index($id))
                then .
                else .devices += [{"deviceID":$id}]
                end
                ' <<< "$CURRENT_FOLDER")

            api                 -X PUT                 -H "Content-Type: application/json"                 -d "$UPDATED_FOLDER"                 "$GUI/rest/config/folders/$FOLDER_ID" >/dev/null
        done

        echo
        echo "Device accepted."
        echo "Folders offered to secondary device."
        echo
        echo "Waiting for connection..."

        while true; do
            CONNECTIONS=$(api "$GUI/rest/system/connections" || echo '{}')
            CONNECTED=$(jq -r                 --arg id "$NEW_DEVICE"                 '.connections[$id].connected // false'                 <<< "$CONNECTIONS")

            if [[ "$CONNECTED" == "true" ]]; then
                echo
                echo "======================================"
                echo " SECONDARY CONNECTED SUCCESSFULLY"
                echo "======================================"
                echo
                break
            fi

            sleep 3
        done

        read -rp "Wait for another secondary device? [y/N]: " MORE
        if [[ ! "$MORE" =~ ^[Yy]$ ]]; then
            break
        fi

        echo "Waiting for another device..."
    fi

    sleep 3
done

echo
echo "Syncthing primary setup finished."
echo "Automatic startup is enabled."
