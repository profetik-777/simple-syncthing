#!/usr/bin/env bash
set -Eeuo pipefail

DEFAULT_GUI="http://127.0.0.1:8384"
GUI="$DEFAULT_GUI"
FORCE_IMMUTABLE=false
INSTALL_METHOD=""
SYNCTHING_BIN=""
CONFIG=""
CURL_TLS_ARGS=()

# Make Linuxbrew available if installed in its standard Linux location.
if [[ -x /home/linuxbrew/.linuxbrew/bin/brew ]] &&
   ! command -v brew >/dev/null 2>&1; then
    export PATH="/home/linuxbrew/.linuxbrew/bin:$PATH"
fi

# Respect the shell's current Syncthing choice first.
# Only fall back to ~/.local/bin if Syncthing is otherwise not on PATH.
if ! command -v syncthing >/dev/null 2>&1 &&
   [[ -x "$HOME/.local/bin/syncthing" ]]; then
    export PATH="$HOME/.local/bin:$PATH"
fi

if [[ "${1:-}" == "--immutable" ]]; then
    FORCE_IMMUTABLE=true
elif [[ -n "${1:-}" ]]; then
    echo "Usage: $0 [--immutable]"
    exit 1
fi

echo "======================================"
echo " Syncthing PRIMARY Setup"
echo "======================================"

is_immutable() {
    [[ "$FORCE_IMMUTABLE" == true ]] ||
    [[ -e /run/ostree-booted ]] ||
    command -v rpm-ostree >/dev/null 2>&1
}

canonical_path() {
    readlink -f -- "$1" 2>/dev/null ||
        printf '%s\n' "$1"
}

ensure_tools() {
    local missing=()
    local cmd

    for cmd in curl jq; do
        command -v "$cmd" >/dev/null 2>&1 ||
            missing+=("$cmd")
    done

    [[ ${#missing[@]} -eq 0 ]] && return 0

    if is_immutable; then
        echo
        echo "Missing required tool(s): ${missing[*]}"

        if command -v brew >/dev/null 2>&1; then
            read -r -p \
                "Install them with Homebrew? [Y/n]: " \
                answer

            answer="${answer:-Y}"

            if [[ "$answer" =~ ^[Yy]$ ]]; then
                brew install "${missing[@]}"
                return 0
            fi
        fi

        echo
        echo "Install the missing tool(s) using a"
        echo "host-supported method, then rerun."

        exit 1
    fi

    if command -v apt >/dev/null 2>&1; then
        sudo apt update
        sudo apt install -y "${missing[@]}"

    elif command -v dnf >/dev/null 2>&1; then
        sudo dnf install -y "${missing[@]}"

    elif command -v pacman >/dev/null 2>&1; then
        sudo pacman -S --needed "${missing[@]}"

    else
        echo "Could not install required tool(s): ${missing[*]}"
        exit 1
    fi
}

detect_existing_syncthing() {
    command -v syncthing >/dev/null 2>&1 ||
        return 1

    SYNCTHING_BIN=$(command -v syncthing)

    echo
    echo "Existing Syncthing installation detected:"
    echo "  $SYNCTHING_BIN"
    echo
    echo "Skipping Syncthing installation."
    echo "Continuing with configuration."

    if command -v brew >/dev/null 2>&1 &&
       brew list --versions syncthing >/dev/null 2>&1; then

        local prefix

        prefix=$(
            brew --prefix 2>/dev/null ||
            true
        )

        if [[ -n "$prefix" &&
              "$SYNCTHING_BIN" == "$prefix"/* ]]; then

            INSTALL_METHOD="homebrew"

        else
            INSTALL_METHOD="existing"
        fi

    else
        INSTALL_METHOD="existing"
    fi
}

install_direct() {
    command -v curl >/dev/null 2>&1 || {
        echo "curl is required."
        exit 1
    }

    command -v tar >/dev/null 2>&1 || {
        echo "tar is required."
        exit 1
    }

    case "$(uname -m)" in

        x86_64)
            local arch="amd64"
            ;;

        aarch64|arm64)
            local arch="arm64"
            ;;

        *)
            echo "Unsupported architecture: $(uname -m)"
            exit 1
            ;;

    esac

    local tmp
    local release
    local version
    local archive
    local url
    local binary

    tmp=$(mktemp -d)

    echo
    echo "Finding latest Syncthing release..."

    release=$(
        curl -fsSL \
            https://api.github.com/repos/syncthing/syncthing/releases/latest
    )

    version=$(
        printf '%s' "$release" |
            grep -o \
                '"tag_name":[[:space:]]*"[^"]*"' |
            head -1 |
            cut -d'"' -f4 ||
        true
    )

    if [[ -z "$version" ]]; then
        rm -rf "$tmp"

        echo "Could not determine latest Syncthing version."

        exit 1
    fi

    archive="syncthing-linux-${arch}-${version}.tar.gz"

    url="https://github.com/syncthing/syncthing/releases/download/${version}/${archive}"

    echo
    echo "Downloading Syncthing $version..."

    curl \
        -fL \
        "$url" \
        -o "$tmp/$archive"

    tar \
        -xzf "$tmp/$archive" \
        -C "$tmp"

    binary=$(
        find "$tmp" \
            -type f \
            -name syncthing \
            -perm -u+x \
            -print \
            -quit
    )

    if [[ -z "$binary" ]]; then
        rm -rf "$tmp"

        echo "Syncthing binary not found in archive."

        exit 1
    fi

    mkdir -p "$HOME/.local/bin"

    install \
        -m 0755 \
        "$binary" \
        "$HOME/.local/bin/syncthing"

    rm -rf "$tmp"

    SYNCTHING_BIN="$HOME/.local/bin/syncthing"

    export PATH="$HOME/.local/bin:$PATH"

    INSTALL_METHOD="direct"

    echo
    echo "Syncthing installed:"
    echo "  $SYNCTHING_BIN"
}

install_homebrew() {
    if ! command -v brew >/dev/null 2>&1; then
        echo "Homebrew is not installed."
        exit 1
    fi

    echo
    echo "Installing Syncthing with Homebrew..."

    brew install syncthing

    SYNCTHING_BIN=$(command -v syncthing)

    INSTALL_METHOD="homebrew"
}

install_normal() {
    if command -v apt >/dev/null 2>&1; then
        sudo apt update
        sudo apt install -y syncthing

    elif command -v dnf >/dev/null 2>&1; then
        sudo dnf install -y syncthing

    elif command -v pacman >/dev/null 2>&1; then
        sudo pacman -S --needed syncthing

    else
        echo "Unsupported package manager."
        exit 1
    fi

    SYNCTHING_BIN=$(command -v syncthing)

    INSTALL_METHOD="package"
}

install_if_needed() {
    if detect_existing_syncthing; then
        return 0
    fi

    if is_immutable; then
        echo
        echo "Immutable Linux detected."
        echo
        echo "How should Syncthing be installed?"
        echo
        echo "  1) Direct download to ~/.local/bin"
        echo "     Recommended"
        echo
        echo "  2) Homebrew"
        echo

        read -r -p "Choice [1]: " choice

        choice="${choice:-1}"

        case "$choice" in

            1)
                install_direct
                ;;

            2)
                install_homebrew
                ;;

            *)
                echo "Invalid choice."
                exit 1
                ;;

        esac

    else
        install_normal
    fi
}

parse_config_path() {
    awk '
        /^Configuration file:/ {
            line=$0

            sub(
                /^Configuration file:[[:space:]]*/,
                "",
                line
            )

            if (length(line)) {
                print line
                exit
            }

            if (getline > 0) {
                gsub(/^[[:space:]]+/, "")
                gsub(/[[:space:]]+$/, "")

                print
                exit
            }
        }
    '
}

find_config() {
    local output
    local detected
    local candidate

    local candidates=()

    if [[ -n "${STCONFDIR:-}" ]]; then
        candidates+=("$STCONFDIR/config.xml")
    fi

    if [[ -n "${STHOMEDIR:-}" ]]; then
        candidates+=("$STHOMEDIR/config.xml")
    fi

    if [[ -n "${XDG_STATE_HOME:-}" ]]; then
        candidates+=(
            "$XDG_STATE_HOME/syncthing/config.xml"
        )
    fi

    if [[ -n "$SYNCTHING_BIN" &&
          -x "$SYNCTHING_BIN" ]]; then

        output=$(
            "$SYNCTHING_BIN" paths \
                2>/dev/null ||
            "$SYNCTHING_BIN" --paths \
                2>/dev/null ||
            true
        )

        detected=$(
            printf '%s\n' "$output" |
                parse_config_path
        )

        if [[ -n "$detected" ]]; then
            candidates+=("$detected")
        fi
    fi

    candidates+=(
        "$HOME/.local/state/syncthing/config.xml"
        "$HOME/.config/syncthing/config.xml"
    )

    for candidate in "${candidates[@]}"; do
        if [[ -f "$candidate" ]]; then
            printf '%s\n' "$candidate"
            return 0
        fi
    done

    return 1
}

set_gui_from_config() {
    local address
    local tls
    local scheme
    local hostport
    local port

    GUI="$DEFAULT_GUI"

    CURL_TLS_ARGS=()

    [[ -n "$CONFIG" &&
       -f "$CONFIG" ]] ||
        return 0

    address=$(
        sed -n \
            '/<gui[ >]/,/<\/gui>/ {
                s:.*<address>\(.*\)</address>.*:\1:p
            }' \
            "$CONFIG" |
        head -1
    )

    tls=$(
        sed -n \
            's:.*<gui[^>]*tls="\([^"]*\)".*:\1:p' \
            "$CONFIG" |
        head -1
    )

    [[ -n "$address" ]] ||
        return 0

    case "$address" in

        unix://*|unixs://*)
            echo
            echo "This Syncthing installation uses a"
            echo "Unix-socket GUI/API address:"
            echo
            echo "  $address"
            echo
            echo "This script does not support that yet."

            exit 1
            ;;

    esac

    if [[ "$address" == http://* ||
          "$address" == https://* ]]; then

        scheme="${address%%://*}"

        hostport="${address#*://}"

    else

        if [[ "$tls" == "true" ]]; then
            scheme="https"
        else
            scheme="http"
        fi

        hostport="$address"
    fi

    case "$hostport" in

        0.0.0.0:*)
            hostport="127.0.0.1:${hostport#*:}"
            ;;

        \[::\]:*)
            port="${hostport##*:}"

            hostport="127.0.0.1:$port"
            ;;

        :*)
            hostport="127.0.0.1$hostport"
            ;;

    esac

    GUI="$scheme://$hostport"

    if [[ "$scheme" == "https" ]]; then
        CURL_TLS_ARGS=(-k)
    fi

    return 0
}

api_health() {
    curl \
        "${CURL_TLS_ARGS[@]}" \
        -fsS \
        "$GUI/rest/noauth/health" \
        >/dev/null \
        2>&1
}

user_syncthing_pids() {
    pgrep \
        -u "$(id -u)" \
        -x syncthing \
        2>/dev/null ||
    true
}

write_user_service() {
    local unit

    unit="$HOME/.config/systemd/user/syncthing.service"

    mkdir -p \
        "$HOME/.config/systemd/user"

    cat > "$unit" <<UNIT
[Unit]
Description=Syncthing - Open Source Continuous File Synchronization
Documentation=https://docs.syncthing.net/
StartLimitIntervalSec=60
StartLimitBurst=4

[Service]
Environment="STLOGFORMATTIMESTAMP="
Environment="STLOGFORMATLEVELSTRING=false"
Environment="STLOGFORMATLEVELSYSLOG=true"
ExecStart=$SYNCTHING_BIN serve --no-browser --no-restart
Restart=on-failure
RestartSec=1
SuccessExitStatus=3 4
RestartForceExitStatus=3 4
SystemCallArchitectures=native
MemoryDenyWriteExecute=true
NoNewPrivileges=true

[Install]
WantedBy=default.target
UNIT

    systemctl \
        --user \
        daemon-reload
}

ensure_systemd_service() {
    local unit

    unit="$HOME/.config/systemd/user/syncthing.service"

    # Earlier versions of Simple Syncthing created
    # a unit containing --logflags=0.
    # Rewrite only that old unit.

    if [[ -f "$unit" ]] &&
       grep -q \
           -- '--logflags=' \
           "$unit"; then

        echo
        echo "Updating older Simple Syncthing systemd unit."

        write_user_service

    elif ! systemctl \
        --user \
        cat syncthing.service \
        >/dev/null \
        2>&1; then

        write_user_service
    fi

    systemctl \
        --user \
        enable syncthing.service \
        >/dev/null
}

ensure_autostart_if_running() {
    if [[ "$INSTALL_METHOD" == "homebrew" ]]; then

        local state

        state=$(
            brew services list \
                2>/dev/null |
            awk \
                '$1 == "syncthing" {
                    print $2
                    exit
                }' ||
            true
        )

        if [[ "$state" == "started" ]]; then
            echo
            echo "Homebrew Syncthing service is already enabled."

        else
            echo
            echo "Syncthing is running outside Homebrew services."
            echo
            echo "Configuration will continue without"
            echo "starting a second Syncthing instance."
            echo
            echo "For Homebrew autostart later:"
            echo
            echo "  brew services start syncthing"
        fi

    else

        ensure_systemd_service

        echo
        echo "systemd user autostart is enabled."
    fi
}

start_service() {
    if [[ "$INSTALL_METHOD" == "homebrew" ]]; then

        echo
        echo "Starting Syncthing through Homebrew..."

        brew services start syncthing

    else

        ensure_systemd_service

        echo
        echo "Starting Syncthing systemd user service..."

        systemctl \
            --user \
            start syncthing.service
    fi
}

wait_for_api() {
    local tries="${1:-30}"
    local i

    for ((i=1; i<=tries; i++)); do

        if api_health; then
            return 0
        fi

        sleep 1

    done

    return 1
}


# ============================================================
# INSTALL / DISCOVER
# ============================================================

install_if_needed

ensure_tools


# Repair a user service created by an older
# Simple Syncthing version before checking processes.

if [[ "$INSTALL_METHOD" != "homebrew" &&
      -f "$HOME/.config/systemd/user/syncthing.service" ]]; then

    ensure_systemd_service
fi


# ============================================================
# FIND / START / REUSE SYNCTHING
# ============================================================

CONFIG=$(
    find_config ||
    true
)

set_gui_from_config


if api_health; then

    echo
    echo "Syncthing is already running."
    echo "Using the existing instance."

    ensure_autostart_if_running


elif [[ -n "$(user_syncthing_pids)" ]]; then

    # Give a currently starting process a little time.

    if wait_for_api 10; then

        echo
        echo "Syncthing is already running."
        echo "Using the existing instance."

        ensure_autostart_if_running

    else

        echo
        echo "A Syncthing process is already running"
        echo "for user $(id -un), but its API is not"
        echo "reachable at:"
        echo
        echo "  $GUI"
        echo
        echo "Refusing to start a second instance."
        echo "That could create configuration/database"
        echo "lock conflicts."
        echo
        echo "Running Syncthing processes:"
        echo

        while read -r pid; do

            [[ -n "$pid" ]] &&
                ps \
                    -o pid=,ppid=,stat=,cmd= \
                    -p "$pid" ||
                true

        done < <(user_syncthing_pids)

        exit 1
    fi


else

    echo
    echo "Starting Syncthing..."

    start_service


    # First run may create config.xml.
    # Discover it again after startup.

    for _ in {1..15}; do

        CONFIG=$(
            find_config ||
            true
        )

        if [[ -n "$CONFIG" ]]; then

            set_gui_from_config

            break
        fi

        sleep 1

    done


    if ! wait_for_api 30; then

        echo
        echo "Syncthing started, but its API"
        echo "never became reachable at:"
        echo
        echo "  $GUI"
        echo
        echo "Check:"
        echo
        echo "  systemctl --user status syncthing --no-pager"

        exit 1
    fi
fi


# ============================================================
# VERIFY ACTIVE CONFIG
# ============================================================

CONFIG=$(
    find_config ||
    true
)


if [[ -z "$CONFIG" ||
      ! -f "$CONFIG" ]]; then

    echo
    echo "Could not locate Syncthing config.xml."

    exit 1
fi


set_gui_from_config


echo
echo "Using Syncthing config:"
echo "  $CONFIG"
echo
echo "Syncthing API:"
echo "  $GUI"


API_KEY=$(
    sed -n \
        's:.*<apikey>\(.*\)</apikey>.*:\1:p' \
        "$CONFIG" |
    head -1
)


if [[ -z "$API_KEY" ]]; then

    echo
    echo "Could not read the Syncthing API key from:"
    echo "  $CONFIG"

    exit 1
fi


api() {
    local endpoint="$1"

    shift || true

    curl \
        "${CURL_TLS_ARGS[@]}" \
        -fsS \
        -H "X-API-Key: $API_KEY" \
        "$@" \
        "$GUI$endpoint"
}


STATUS=$(
    api "/rest/system/status" \
        2>/dev/null ||
    true
)


if [[ -z "$STATUS" ]] ||
   ! jq -e . \
       >/dev/null \
       2>&1 \
       <<< "$STATUS"; then

    echo
    echo "The Syncthing GUI is reachable,"
    echo "but the authenticated API check failed."
    echo
    echo "Config:"
    echo "  $CONFIG"
    echo
    echo "API:"
    echo "  $GUI"

    exit 1
fi


DEVICE_ID=$(
    jq -r \
        '.myID // empty' \
        <<< "$STATUS"
)


if [[ -z "$DEVICE_ID" ]]; then

    echo "Could not retrieve the Syncthing Device ID."

    exit 1
fi


# Ask the running instance which config it is really using.

SYSTEM_PATHS=$(
    api "/rest/system/paths" \
        2>/dev/null ||
    true
)


if jq -e . \
    >/dev/null \
    2>&1 \
    <<< "$SYSTEM_PATHS"; then

    ACTIVE_CONFIG=$(
        jq -r \
            '.config // empty' \
            <<< "$SYSTEM_PATHS"
    )


    if [[ -n "$ACTIVE_CONFIG" ]]; then

        ACTIVE_CONFIG=$(
            canonical_path "$ACTIVE_CONFIG"
        )

        SELECTED_CONFIG=$(
            canonical_path "$CONFIG"
        )


        if [[ "$ACTIVE_CONFIG" != "$SELECTED_CONFIG" ]]; then

            echo
            echo "Running Syncthing uses a different config."
            echo "Stopping for safety."
            echo
            echo "Running:"
            echo "  $ACTIVE_CONFIG"
            echo
            echo "Selected:"
            echo "  $SELECTED_CONFIG"

            exit 1
        fi
    fi
fi


echo
echo "PRIMARY DEVICE ID"
echo "--------------------------------------"
echo "$DEVICE_ID"
echo "--------------------------------------"


# ============================================================
# FOLDER DECLARATION
# ============================================================

echo
echo "Enter folders to synchronize."
echo "Paste ONE folder path per line."
echo "Press ENTER on an empty line when finished."
echo


declare -a SYNC_PATHS=()


while true; do

    read -r -p \
        "Folder: " \
        INPUT_PATH


    [[ -z "$INPUT_PATH" ]] &&
        break


    INPUT_PATH="${INPUT_PATH/#\~/$HOME}"


    if [[ "$INPUT_PATH" != "/" ]]; then
        INPUT_PATH="${INPUT_PATH%/}"
    fi


    if [[ ! -d "$INPUT_PATH" ]]; then

        echo
        echo "Folder does not exist:"
        echo "  $INPUT_PATH"

        read -r -p \
            "Create it? [y/N]: " \
            create


        if [[ ! "$create" =~ ^[Yy]$ ]]; then

            echo "Skipped."

            continue
        fi


        mkdir -p "$INPUT_PATH"
    fi


    INPUT_PATH=$(
        canonical_path "$INPUT_PATH"
    )


    duplicate=false


    for path in "${SYNC_PATHS[@]:-}"; do

        if [[ "$path" == "$INPUT_PATH" ]]; then

            duplicate=true

            break
        fi

    done


    if [[ "$duplicate" == true ]]; then

        echo "Already selected. Skipping."

        continue
    fi


    SYNC_PATHS+=("$INPUT_PATH")

    echo "Added."

done


if [[ ${#SYNC_PATHS[@]} -eq 0 ]]; then

    echo
    echo "No folders selected."
    echo "Nothing to configure."

    exit 1
fi


echo
echo "Folders selected:"


for i in "${!SYNC_PATHS[@]}"; do

    printf \
        "  %d. %s\n" \
        "$((i + 1))" \
        "${SYNC_PATHS[$i]}"

done


echo


read -r -p \
    "Continue? [Y/n]: " \
    confirm


confirm="${confirm:-Y}"


if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
    exit 0
fi


# ============================================================
# EXISTING SYNCTHING FOLDERS
# ============================================================

EXISTING_FOLDERS=$(
    api "/rest/config/folders"
)


if ! jq -e \
    'type == "array"' \
    >/dev/null \
    2>&1 \
    <<< "$EXISTING_FOLDERS"; then

    echo "Could not read Syncthing folders."

    exit 1
fi


existing_folder_id_for_path() {
    local target="$1"

    local id
    local path


    while IFS=$'\t' \
        read -r id path; do

        path="${path/#\~/$HOME}"


        if [[ "$path" != "/" ]]; then
            path="${path%/}"
        fi


        path=$(
            canonical_path "$path"
        )


        if [[ "$path" == "$target" ]]; then

            printf '%s\n' "$id"

            return 0
        fi

    done < <(
        jq -r \
            '.[] | [.id, .path] | @tsv' \
            <<< "$EXISTING_FOLDERS"
    )


    return 1
}


folder_id_exists() {
    jq \
        -e \
        --arg id "$1" \
        '.[] | select(.id == $id)' \
        >/dev/null \
        2>&1 \
        <<< "$EXISTING_FOLDERS"
}


# ============================================================
# CREATE OR REUSE FOLDERS
# ============================================================

declare -a FOLDER_IDS=()


for SYNC_PATH in "${SYNC_PATHS[@]}"; do

    EXISTING_ID=$(
        existing_folder_id_for_path \
            "$SYNC_PATH" ||
        true
    )


    if [[ -n "$EXISTING_ID" ]]; then

        echo
        echo "Already configured, reusing folder:"
        echo
        echo "  Path: $SYNC_PATH"
        echo "  ID:   $EXISTING_ID"

        FOLDER_IDS+=("$EXISTING_ID")

        continue
    fi


    LABEL=$(
        basename "$SYNC_PATH"
    )


    BASE_ID=$(
        printf '%s' "$LABEL" |
            tr '[:upper:]' '[:lower:]' |
            tr -cs 'a-z0-9' '-'
    )


    BASE_ID="${BASE_ID#-}"
    BASE_ID="${BASE_ID%-}"


    if [[ -z "$BASE_ID" ]]; then
        BASE_ID="folder"
    fi


    FOLDER_ID="$BASE_ID"

    n=2


    while \
        folder_id_exists "$FOLDER_ID" ||
        [[ " ${FOLDER_IDS[*]} " == *" $FOLDER_ID "* ]]
    do

        FOLDER_ID="${BASE_ID}-${n}"

        ((n++))

    done


    echo
    echo "Creating Syncthing folder:"
    echo
    echo "  Label: $LABEL"
    echo "  Path:  $SYNC_PATH"
    echo "  ID:    $FOLDER_ID"


    TEMPLATE=$(
        api "/rest/config/defaults/folder"
    )


    FOLDER_JSON=$(
        jq \
            --arg id "$FOLDER_ID" \
            --arg label "$LABEL" \
            --arg path "$SYNC_PATH" \
            --arg device "$DEVICE_ID" \
            '
            .id=$id |
            .label=$label |
            .path=$path |
            .type="sendreceive" |
            .devices=[
                {
                    "deviceID":$device
                }
            ]
            ' \
            <<< "$TEMPLATE"
    )


    api \
        "/rest/config/folders" \
        -X POST \
        -H "Content-Type: application/json" \
        -d "$FOLDER_JSON" \
        >/dev/null


    FOLDER_IDS+=("$FOLDER_ID")


    EXISTING_FOLDERS=$(
        api "/rest/config/folders"
    )


    echo "Added."

done


echo
echo "All selected folders are configured."


# ============================================================
# WAIT FOR SECONDARY
# ============================================================

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

    PENDING=$(
        api \
            "/rest/cluster/pending/devices" \
            2>/dev/null ||
        echo '{}'
    )


    NEW_DEVICE=$(
        jq -r \
            'keys[0] // empty' \
            <<< "$PENDING"
    )


    if [[ -n "$NEW_DEVICE" ]]; then

        echo
        echo "Secondary device detected:"
        echo "$NEW_DEVICE"
        echo


        read -r -p \
            "Accept this device? [Y/n]: " \
            answer


        answer="${answer:-Y}"


        if [[ ! "$answer" =~ ^[Yy]$ ]]; then

            sleep 3

            continue
        fi


        DEVICE_TEMPLATE=$(
            api "/rest/config/defaults/device"
        )


        DEVICE_JSON=$(
            jq \
                --arg id "$NEW_DEVICE" \
                '
                .deviceID=$id |
                .name="Syncthing Secondary"
                ' \
                <<< "$DEVICE_TEMPLATE"
        )


        api \
            "/rest/config/devices" \
            -X POST \
            -H "Content-Type: application/json" \
            -d "$DEVICE_JSON" \
            >/dev/null


        for FOLDER_ID in "${FOLDER_IDS[@]}"; do

            CURRENT=$(
                api \
                    "/rest/config/folders/$FOLDER_ID"
            )


            UPDATED=$(
                jq \
                    --arg id "$NEW_DEVICE" \
                    '
                    if (
                        .devices |
                        map(.deviceID) |
                        index($id)
                    )
                    then
                        .
                    else
                        .devices += [
                            {
                                "deviceID":$id
                            }
                        ]
                    end
                    ' \
                    <<< "$CURRENT"
            )


            api \
                "/rest/config/folders/$FOLDER_ID" \
                -X PUT \
                -H "Content-Type: application/json" \
                -d "$UPDATED" \
                >/dev/null

        done


        echo
        echo "Device accepted."
        echo "Waiting for connection..."


        while true; do

            CONNECTIONS=$(
                api \
                    "/rest/system/connections" \
                    2>/dev/null ||
                echo '{}'
            )


            CONNECTED=$(
                jq \
                    -r \
                    --arg id "$NEW_DEVICE" \
                    '.connections[$id].connected // false' \
                    <<< "$CONNECTIONS"
            )


            if [[ "$CONNECTED" == "true" ]]; then
                break
            fi


            sleep 3

        done


        echo
        echo "Secondary connected successfully."
        echo


        read -r -p \
            "Wait for another secondary device? [y/N]: " \
            more


        if [[ ! "$more" =~ ^[Yy]$ ]]; then
            break
        fi
    fi


    sleep 3

done


echo
echo "Syncthing primary setup finished."
echo "Startup configuration is complete."
