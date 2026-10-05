#!/usr/bin/env bash
set -euo pipefail

GUI="http://127.0.0.1:8384"
FORCE_IMMUTABLE=false
INSTALL_METHOD=""

if [[ "${1:-}" == "--immutable" ]]; then
    FORCE_IMMUTABLE=true
elif [[ -n "${1:-}" ]]; then
    echo "Usage: $0 [--immutable]"
    exit 1
fi

echo "======================================"
echo " Syncthing PRIMARY Setup"
echo "======================================"

is_immutable_system() {
    [[ "$FORCE_IMMUTABLE" == true ]] ||
    [[ -e /run/ostree-booted ]] ||
    command -v rpm-ostree >/dev/null 2>&1
}

install_syncthing_direct() {
    echo
    echo "Direct user-local installation selected."
    echo "Target: $HOME/.local/bin/syncthing"
    echo "Service: systemd user service for $(id -un)"
    echo

    for CMD in curl tar; do
        if ! command -v "$CMD" >/dev/null 2>&1; then
            echo "Missing required host command: $CMD"
            echo "Install it using your immutable OS's supported host method, then rerun."
            exit 1
        fi
    done

    case "$(uname -m)" in
        x86_64) ST_ARCH="amd64" ;;
        aarch64|arm64) ST_ARCH="arm64" ;;
        *)
            echo "Unsupported architecture: $(uname -m)"
            exit 1
            ;;
    esac

    TMP_DIR=$(mktemp -d)
    trap 'rm -rf "$TMP_DIR"' EXIT

    echo "Finding latest Syncthing release..."
    RELEASE_JSON=$(curl -fsSL https://api.github.com/repos/syncthing/syncthing/releases/latest)
    VERSION=$(printf '%s' "$RELEASE_JSON" | grep -o '"tag_name":[[:space:]]*"[^"]*"' | head -1 | cut -d'"' -f4)

    if [[ -z "$VERSION" ]]; then
        echo "Could not determine the latest Syncthing release."
        exit 1
    fi

    ARCHIVE="syncthing-linux-${ST_ARCH}-${VERSION}.tar.gz"
    URL="https://github.com/syncthing/syncthing/releases/download/${VERSION}/${ARCHIVE}"

    echo "Downloading Syncthing ${VERSION}..."
    curl -fL "$URL" -o "$TMP_DIR/$ARCHIVE"
    tar -xzf "$TMP_DIR/$ARCHIVE" -C "$TMP_DIR"

    BINARY=$(find "$TMP_DIR" -type f -name syncthing -perm -u+x | head -1)
    if [[ -z "$BINARY" ]]; then
        echo "Syncthing binary was not found in the downloaded archive."
        exit 1
    fi

    mkdir -p "$HOME/.local/bin"
    install -m 0755 "$BINARY" "$HOME/.local/bin/syncthing"
    export PATH="$HOME/.local/bin:$PATH"

    mkdir -p "$HOME/.config/systemd/user"
    cat > "$HOME/.config/systemd/user/syncthing.service" <<'EOF'
[Unit]
Description=Syncthing - Open Source Continuous File Synchronization
Documentation=https://docs.syncthing.net/
After=network.target

[Service]
ExecStart=%h/.local/bin/syncthing serve --no-browser --no-restart --logflags=0
Restart=on-failure
RestartSec=5
SuccessExitStatus=3 4
RestartForceExitStatus=3 4

[Install]
WantedBy=default.target
EOF

    systemctl --user daemon-reload
    INSTALL_METHOD="direct"

    echo
    echo "Syncthing installed locally for user: $(id -un)"
}

install_syncthing_homebrew() {
    echo
    echo "Homebrew installation selected."

    if ! command -v brew >/dev/null 2>&1; then
        echo "Homebrew is not installed."
        echo "Install Homebrew first, then rerun this script."
        exit 1
    fi

    brew install syncthing
    INSTALL_METHOD="homebrew"

    echo
    echo "Syncthing installed with Homebrew."
}

choose_immutable_install_method() {
    echo
    echo "Immutable Linux detected."
    echo
    echo "How would you like to install Syncthing?"
    echo
    echo "  1) Direct download to ~/.local/bin"
    echo "     Recommended for immutable systems."
    echo
    echo "  2) Homebrew"
    echo "     Uses: brew install syncthing"
    echo

    read -r -p "Choice [1]: " INSTALL_CHOICE
    INSTALL_CHOICE="${INSTALL_CHOICE:-1}"

    case "$INSTALL_CHOICE" in
        1)
            install_syncthing_direct
            ;;
        2)
            install_syncthing_homebrew
            ;;
        *)
            echo "Invalid choice."
            exit 1
            ;;
    esac
}

detect_existing_syncthing() {
    if command -v syncthing >/dev/null 2>&1; then
        SYNCTHING_BIN=$(command -v syncthing)
        echo
        echo "Existing Syncthing installation detected:"
        echo "  $SYNCTHING_BIN"
        echo
        echo "Skipping Syncthing installation and continuing with configuration."

        if command -v brew >/dev/null 2>&1 && brew list --versions syncthing >/dev/null 2>&1; then
            INSTALL_METHOD="homebrew"
        else
            INSTALL_METHOD="existing"
        fi

        return 0
    fi

    return 1
}

ensure_syncthing_running() {
    echo
    echo "Checking whether Syncthing is already running..."

    if curl -sf "$GUI/rest/noauth/health" >/dev/null 2>&1; then
        echo "Syncthing is already running. Using the existing instance."
        return
    fi

    echo "Syncthing is installed but not currently responding on $GUI."

    if [[ "$INSTALL_METHOD" == "homebrew" ]]; then
        echo "Starting the existing Homebrew Syncthing service..."
        brew services start syncthing
    elif systemctl --user cat syncthing.service >/dev/null 2>&1; then
        echo "Starting the existing systemd user service..."
        systemctl --user enable --now syncthing.service
    else
        SYNCTHING_BIN=$(command -v syncthing)

        echo "No Syncthing user service was found."
        echo "Creating a systemd user service for:"
        echo "  $SYNCTHING_BIN"

        mkdir -p "$HOME/.config/systemd/user"
        cat > "$HOME/.config/systemd/user/syncthing.service" <<EOF
[Unit]
Description=Syncthing - Open Source Continuous File Synchronization
Documentation=https://docs.syncthing.net/
After=network.target

[Service]
ExecStart=$SYNCTHING_BIN serve --no-browser --no-restart --logflags=0
Restart=on-failure
RestartSec=5
SuccessExitStatus=3 4
RestartForceExitStatus=3 4

[Install]
WantedBy=default.target
EOF

        systemctl --user daemon-reload
        systemctl --user enable --now syncthing.service
    fi

    echo "Waiting for Syncthing API..."
    until curl -sf "$GUI/rest/noauth/health" >/dev/null 2>&1; do
        sleep 2
    done
}

install_packages() {
    if is_immutable_system; then
        for CMD in jq curl; do
            if ! command -v "$CMD" >/dev/null 2>&1; then
                echo "Missing required host command on immutable system: $CMD"
                echo "Install it using your OS's supported host method, then rerun."
                exit 1
            fi
        done

        if ! command -v syncthing >/dev/null 2>&1; then
            choose_immutable_install_method
        else
            echo "Syncthing is already installed. Skipping installation."
            if command -v brew >/dev/null 2>&1 && brew list --versions syncthing >/dev/null 2>&1; then
                INSTALL_METHOD="homebrew"
            else
                INSTALL_METHOD="existing"
            fi
        fi
        return
    fi

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

if detect_existing_syncthing; then
    :
elif is_immutable_system; then
    echo
    echo "Immutable mode: ON"
    install_packages
else
    for CMD in jq curl; do
        if ! command -v "$CMD" >/dev/null 2>&1; then
            echo "Missing dependency: $CMD"
            install_packages
            break
        fi
    done

    if ! command -v syncthing >/dev/null 2>&1; then
        install_packages
    fi
fi

export PATH="$HOME/.local/bin:$PATH"

ensure_syncthing_running

find_syncthing_config() {
    local detected=""

    if command -v syncthing >/dev/null 2>&1; then
        detected=$(syncthing --paths 2>/dev/null | awk -F': ' '/^Configuration file:/ {print $2; exit}')
    fi

    if [[ -n "$detected" && -f "$detected" ]]; then
        printf '%s\n' "$detected"
        return 0
    fi

    if [[ -f "$HOME/.local/state/syncthing/config.xml" ]]; then
        printf '%s\n' "$HOME/.local/state/syncthing/config.xml"
        return 0
    fi

    if [[ -f "$HOME/.config/syncthing/config.xml" ]]; then
        printf '%s\n' "$HOME/.config/syncthing/config.xml"
        return 0
    fi

    return 1
}

CONFIG=$(find_syncthing_config || true)

if [[ -z "$CONFIG" || ! -f "$CONFIG" ]]; then
    echo
    echo "Could not locate the Syncthing config used by this installation."
    echo "Try running:"
    echo "  syncthing --paths"
    exit 1
fi

echo
echo "Using Syncthing config:"
echo "  $CONFIG"

API_KEY=$(sed -n 's:.*<apikey>\(.*\)</apikey>.*:\1:p' "$CONFIG" | head -1)

if [[ -z "$API_KEY" ]]; then
    echo "Could not determine Syncthing API key from:"
    echo "  $CONFIG"
    exit 1
fi

api() {
    curl -sS -H "X-API-Key: $API_KEY" "$@"
}

STATUS_RESPONSE=$(api "$GUI/rest/system/status" || true)

if ! jq -e . >/dev/null 2>&1 <<< "$STATUS_RESPONSE"; then
    echo
    echo "Syncthing is running, but the API response was not valid JSON."
    echo "This usually means the script found the wrong config/API key."
    echo
    echo "Config selected:"
    echo "  $CONFIG"
    echo
    echo "Syncthing says its paths are:"
    syncthing --paths 2>/dev/null || true
    echo
    echo "API response:"
    printf '%s\n' "$STATUS_RESPONSE"
    exit 1
fi

DEVICE_ID=$(jq -r '.myID' <<< "$STATUS_RESPONSE")

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
