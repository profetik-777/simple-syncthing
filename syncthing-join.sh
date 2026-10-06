#!/usr/bin/env bash
set -Eeuo pipefail

DEFAULT_GUI="http://127.0.0.1:8384"
GUI="$DEFAULT_GUI"
FORCE_IMMUTABLE=false
INSTALL_METHOD=""
SYNCTHING_BIN=""
CONFIG=""
CURL_TLS_ARGS=()

if [[ -x /home/linuxbrew/.linuxbrew/bin/brew ]] &&
   ! command -v brew >/dev/null 2>&1; then
    export PATH="/home/linuxbrew/.linuxbrew/bin:$PATH"
fi

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
echo " Syncthing SECONDARY / JOIN Setup"
echo "======================================"

is_immutable() {
    [[ "$FORCE_IMMUTABLE" == true ]] ||
    [[ -e /run/ostree-booted ]] ||
    command -v rpm-ostree >/dev/null 2>&1
}

canonical_path() {
    readlink -f -- "$1" 2>/dev/null || printf '%s\n' "$1"
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
            read -r -p "Install them with Homebrew? [Y/n]: " answer
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
        echo "Could not install: ${missing[*]}"
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

    local arch
    local tmp
    local release
    local version
    local archive
    local url
    local binary

    case "$(uname -m)" in
        x86_64)
            arch="amd64"
            ;;
        aarch64|arm64)
            arch="arm64"
            ;;
        *)
            echo "Unsupported architecture: $(uname -m)"
            exit 1
            ;;
    esac

    tmp=$(mktemp -d)

    release=$(
        curl -fsSL \
            https://api.github.com/repos/syncthing/syncthing/releases/latest
    )

    version=$(
        printf '%s' "$release" |
            grep -o '"tag_name":[[:space:]]*"[^"]*"' |
            head -1 |
            cut -d'"' -f4 ||
        true
    )

    if [[ -z "$version" ]]; then
        rm -rf "$tmp"

        echo "Could not determine Syncthing version."

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

        echo "Syncthing binary not found."

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
}

install_homebrew() {
    command -v brew >/dev/null 2>&1 || {
        echo "Homebrew is not installed."
        exit 1
    }

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
        echo "  1) Direct download to ~/.local/bin"
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
            echo "Unix-socket GUI/API addresses are not supported yet:"
            echo "  $address"

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
    mkdir -p \
        "$HOME/.config/systemd/user"

    cat > \
        "$HOME/.config/systemd/user/syncthing.service" <<UNIT
[Unit]
Description=Syncthing - Open Source Continuous File Synchronization
Documentation=https://docs.syncthing.net/
StartLimitIntervalSec=60
StartLimitBurst=4

[Service]
ExecStart=$SYNCTHING_BIN serve --no-browser --no-restart
Restart=on-failure
RestartSec=1
SuccessExitStatus=3 4
RestartForceExitStatus=3 4
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
            echo "Not starting a second instance."
        fi

    else

        ensure_systemd_service

        echo
        echo "systemd user autostart is enabled."
    fi
}

start_service() {
    if [[ "$INSTALL_METHOD" == "homebrew" ]]; then

        brew services start syncthing

    else

        ensure_systemd_service

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
# INSTALL / START / REUSE SYNCTHING
# ============================================================

install_if_needed

ensure_tools


if [[ "$INSTALL_METHOD" != "homebrew" &&
      -f "$HOME/.config/systemd/user/syncthing.service" ]]; then

    ensure_systemd_service
fi


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

    if wait_for_api 10; then

        echo
        echo "Syncthing is already running."
        echo "Using the existing instance."

        ensure_autostart_if_running

    else

        echo
        echo "A Syncthing process is running,"
        echo "but its API is not reachable at:"
        echo
        echo "  $GUI"
        echo
        echo "Refusing to start a second instance."

        exit 1
    fi


else

    echo
    echo "Starting Syncthing..."

    start_service


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
        echo "Syncthing API did not become reachable at:"
        echo
        echo "  $GUI"

        exit 1
    fi
fi


# ============================================================
# VERIFY CONFIG / API
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

    echo "Could not read the Syncthing API key."

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
    echo "Authenticated Syncthing API check failed."

    exit 1
fi


LOCAL_ID=$(
    jq -r \
        '.myID // empty' \
        <<< "$STATUS"
)


if [[ -z "$LOCAL_ID" ]]; then

    echo "Could not retrieve local Device ID."

    exit 1
fi


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
echo "THIS DEVICE ID"
echo "--------------------------------------"
echo "$LOCAL_ID"
echo "--------------------------------------"
echo


# ============================================================
# PRIMARY DEVICE
# ============================================================

read -r -p \
    "Paste PRIMARY Device ID: " \
    PRIMARY_ID


PRIMARY_ID=$(
    printf '%s' "$PRIMARY_ID" |
        tr -d '[:space:]'
)


if [[ -z "$PRIMARY_ID" ]]; then

    echo "Primary Device ID is required."

    exit 1
fi


if [[ "$PRIMARY_ID" == "$LOCAL_ID" ]]; then

    echo "A device cannot join itself."

    exit 1
fi


DEVICES=$(
    api "/rest/config/devices"
)


if ! jq -e \
    'type == "array"' \
    >/dev/null \
    2>&1 \
    <<< "$DEVICES"; then

    echo "Could not read Syncthing devices."

    exit 1
fi


if jq -e \
    --arg id "$PRIMARY_ID" \
    '.[] | select(.deviceID == $id)' \
    >/dev/null \
    2>&1 \
    <<< "$DEVICES"; then

    echo
    echo "Primary device is already configured."

else

    echo
    echo "Adding primary device..."


    DEVICE_TEMPLATE=$(
        api "/rest/config/defaults/device"
    )


    DEVICE_JSON=$(
        jq \
            --arg id "$PRIMARY_ID" \
            '
            .deviceID=$id |
            .name="Syncthing Primary"
            ' \
            <<< "$DEVICE_TEMPLATE"
    )


    api \
        "/rest/config/devices" \
        -X POST \
        -H "Content-Type: application/json" \
        -d "$DEVICE_JSON" \
        >/dev/null


    echo "Primary device added."
fi


# ============================================================
# WAIT FOR PRIMARY
# ============================================================

echo
echo "Waiting for the primary machine to accept this device..."


while true; do

    CONNECTIONS=$(
        api "/rest/system/connections" \
            2>/dev/null ||
        echo '{}'
    )


    CONNECTED=$(
        jq -r \
            --arg id "$PRIMARY_ID" \
            '.connections[$id].connected // false' \
            <<< "$CONNECTIONS"
    )


    if [[ "$CONNECTED" == "true" ]]; then
        break
    fi


    sleep 3

done


echo
echo "Primary connected."


# ============================================================
# FIND FOLDER OFFERS
# ============================================================

existing_shared_folders_with_primary() {
    api "/rest/config/folders" |
        jq -r \
            --arg id "$PRIMARY_ID" \
            '
            .[] |
            select(
                any(.devices[]?; .deviceID == $id)
            ) |
            [.id, (.label // .id), .path] |
            @tsv
            '
}


pending_folders() {
    api \
        "/rest/cluster/pending/folders" \
        -G \
        --data-urlencode "device=$PRIMARY_ID" \
        2>/dev/null ||
    echo '{}'
}


echo
echo "Waiting for folder offers from primary..."


PENDING="{}"


for _ in {1..10}; do

    PENDING=$(
        pending_folders
    )


    OFFER_COUNT=$(
        jq \
            'length' \
            <<< "$PENDING"
    )


    if (( OFFER_COUNT > 0 )); then
        break
    fi


    sleep 3

done


OFFER_COUNT=$(
    jq \
        'length' \
        <<< "$PENDING"
)


if (( OFFER_COUNT == 0 )); then

    EXISTING_SHARED=$(
        existing_shared_folders_with_primary ||
        true
    )


    if [[ -n "$EXISTING_SHARED" ]]; then

        echo
        echo "No new folder offers are pending."
        echo "Existing shares with the primary:"
        echo


        while IFS=$'\t' \
            read -r id label path; do

            [[ -z "$id" ]] &&
                continue

            echo "  $label"
            echo "    ID:   $id"
            echo "    Path: $path"

        done <<< "$EXISTING_SHARED"


        exit 0
    fi


    echo
    echo "No folder offers yet."
    echo "Continuing to wait..."


    while true; do

        PENDING=$(
            pending_folders
        )


        OFFER_COUNT=$(
            jq \
                'length' \
                <<< "$PENDING"
        )


        if (( OFFER_COUNT > 0 )); then
            break
        fi


        sleep 3

    done
fi


echo
echo "Primary offered $OFFER_COUNT folder(s)."


# ============================================================
# PATH SAFETY
# ============================================================

configured_folder_for_path() {
    local target="$1"
    local folders
    local id
    local path


    folders=$(
        api "/rest/config/folders"
    )


    while IFS=$'\t' \
        read -r id path; do

        path="${path/#\~/$HOME}"


        if [[ "$path" != "/" ]]; then
            path="${path%/}"
        fi


        if [[ -e "$path" ]]; then

            path=$(
                canonical_path "$path"
            )
        fi


        if [[ "$target" == "$path" ]]; then

            printf '%s\n' "$id"

            return 0
        fi

    done < <(
        jq -r \
            '.[] | [.id, .path] | @tsv' \
            <<< "$folders"
    )


    return 1
}


# ============================================================
# ACCEPT FOLDERS
# ============================================================

declare -a ACCEPTED_IDS=()
declare -a ACCEPTED_LABELS=()
declare -a ACCEPTED_PATHS=()


mapfile -t FOLDER_IDS < <(
    jq -r \
        'keys[]' \
        <<< "$PENDING"
)


for FOLDER_ID in "${FOLDER_IDS[@]}"; do

    CURRENT_PENDING=$(
        pending_folders
    )


    if ! jq -e \
        --arg id "$FOLDER_ID" \
        'has($id)' \
        >/dev/null \
        2>&1 \
        <<< "$CURRENT_PENDING"; then

        continue
    fi


    EXISTING_FOLDER=$(
        api \
            "/rest/config/folders/$FOLDER_ID" \
            2>/dev/null ||
        true
    )


    if jq -e \
        'type == "object" and (.id // "") != ""' \
        >/dev/null \
        2>&1 \
        <<< "$EXISTING_FOLDER"; then

        echo
        echo "Folder ID $FOLDER_ID already exists locally."
        echo "Skipping it rather than replacing"
        echo "an existing folder configuration."

        continue
    fi


    FOLDER_LABEL=$(
        jq -r \
            --arg folder "$FOLDER_ID" \
            --arg device "$PRIMARY_ID" \
            '
            .[$folder]
            .offeredBy[$device]
            .label // $folder
            ' \
            <<< "$CURRENT_PENDING"
    )


    RECEIVE_ENCRYPTED=$(
        jq -r \
            --arg folder "$FOLDER_ID" \
            --arg device "$PRIMARY_ID" \
            '
            .[$folder]
            .offeredBy[$device]
            .receiveEncrypted // false
            ' \
            <<< "$CURRENT_PENDING"
    )


    echo
    echo "======================================"
    echo " FOLDER OFFER"
    echo "======================================"
    echo "Name: $FOLDER_LABEL"
    echo "ID:   $FOLDER_ID"


    if [[ "$RECEIVE_ENCRYPTED" == "true" ]]; then

        echo
        echo "Encrypted folder offers are not automated yet."
        echo "Skipping."

        continue
    fi


    DEFAULT_PATH="$HOME/$FOLDER_LABEL"


    while true; do

        echo

        read -r -p \
            "Local path [$DEFAULT_PATH]: " \
            LOCAL_PATH


        LOCAL_PATH="${LOCAL_PATH:-$DEFAULT_PATH}"

        LOCAL_PATH="${LOCAL_PATH/#\~/$HOME}"


        if [[ "$LOCAL_PATH" != "/" ]]; then
            LOCAL_PATH="${LOCAL_PATH%/}"
        fi


        COMPARE_PATH="$LOCAL_PATH"


        if [[ -e "$LOCAL_PATH" ]]; then

            COMPARE_PATH=$(
                canonical_path "$LOCAL_PATH"
            )
        fi


        PATH_OWNER=$(
            configured_folder_for_path \
                "$COMPARE_PATH" ||
            true
        )


        if [[ -n "$PATH_OWNER" &&
              "$PATH_OWNER" != "$FOLDER_ID" ]]; then

            echo
            echo "That path is already used by"
            echo "Syncthing folder:"
            echo
            echo "  $PATH_OWNER"
            echo
            echo "Choose a different local path."

            continue
        fi


        break

    done


    if [[ -d "$LOCAL_PATH" ]] &&
       [[ -n "$(
           find "$LOCAL_PATH" \
               -mindepth 1 \
               -maxdepth 1 \
               -print \
               -quit \
               2>/dev/null
       )" ]]; then

        echo
        echo "Files already exist in:"
        echo
        echo "  $LOCAL_PATH"
        echo
        echo "Choose:"
        echo
        echo "  1) MERGE"
        echo "     Keep local files and synchronize both sides."
        echo
        echo "  2) REPLACE LOCAL"
        echo "     Back up the local folder first."
        echo
        echo "  3) SKIP"
        echo


        read -r -p \
            "Choice [1]: " \
            CHOICE


        CHOICE="${CHOICE:-1}"


        case "$CHOICE" in

            1)
                echo "Merge selected."
                ;;

            2)
                TIMESTAMP=$(
                    date '+%Y-%m-%d_%H-%M-%S'
                )


                BACKUP="${LOCAL_PATH}.pre-syncthing-backup-${TIMESTAMP}"


                if [[ -e "$BACKUP" ]]; then
                    BACKUP="${BACKUP}-$$"
                fi


                echo
                echo "Backing up existing folder to:"
                echo "  $BACKUP"


                mv \
                    "$LOCAL_PATH" \
                    "$BACKUP"


                mkdir -p \
                    "$LOCAL_PATH"
                ;;

            3)
                echo "Skipping $FOLDER_LABEL."
                continue
                ;;

            *)
                echo "Invalid selection."
                echo "Skipping $FOLDER_LABEL."
                continue
                ;;

        esac

    else

        mkdir -p \
            "$LOCAL_PATH"
    fi


    echo
    echo "Accepting $FOLDER_LABEL..."


    FOLDER_TEMPLATE=$(
        api \
            "/rest/config/defaults/folder"
    )


    FOLDER_JSON=$(
        jq \
            --arg id "$FOLDER_ID" \
            --arg label "$FOLDER_LABEL" \
            --arg path "$LOCAL_PATH" \
            --arg local "$LOCAL_ID" \
            --arg primary "$PRIMARY_ID" \
            '
            .id=$id |
            .label=$label |
            .path=$path |
            .type="sendreceive" |
            .devices=[
                {
                    "deviceID":$local
                },
                {
                    "deviceID":$primary
                }
            ]
            ' \
            <<< "$FOLDER_TEMPLATE"
    )


    api \
        "/rest/config/folders" \
        -X POST \
        -H "Content-Type: application/json" \
        -d "$FOLDER_JSON" \
        >/dev/null


    ACCEPTED_IDS+=(
        "$FOLDER_ID"
    )


    ACCEPTED_LABELS+=(
        "$FOLDER_LABEL"
    )


    ACCEPTED_PATHS+=(
        "$LOCAL_PATH"
    )


    echo "Accepted."

done


if [[ ${#ACCEPTED_IDS[@]} -eq 0 ]]; then

    echo
    echo "No new folders were accepted."

    exit 0
fi


# ============================================================
# INITIAL SYNC
# ============================================================

echo
echo "======================================"
echo " INITIAL SYNCHRONIZATION"
echo "======================================"


for i in "${!ACCEPTED_IDS[@]}"; do

    FOLDER_ID="${ACCEPTED_IDS[$i]}"

    FOLDER_LABEL="${ACCEPTED_LABELS[$i]}"

    LOCAL_PATH="${ACCEPTED_PATHS[$i]}"


    echo
    echo "Synchronizing:"
    echo "  $FOLDER_LABEL"
    echo "  $LOCAL_PATH"


    while true; do

        REMOTE_COMPLETION=$(
            api \
                "/rest/db/completion" \
                -G \
                --data-urlencode "device=$PRIMARY_ID" \
                --data-urlencode "folder=$FOLDER_ID" \
                2>/dev/null ||
            echo '{}'
        )


        REMOTE_STATE=$(
            jq -r \
                '.remoteState // "unknown"' \
                <<< "$REMOTE_COMPLETION"
        )


        if [[ "$REMOTE_STATE" == "valid" ]]; then
            break
        fi


        printf \
            "\rWaiting for primary folder handshake...   "


        sleep 2

    done


    echo


    while true; do

        LOCAL_COMPLETION=$(
            api \
                "/rest/db/completion" \
                -G \
                --data-urlencode "folder=$FOLDER_ID" \
                2>/dev/null ||
            echo '{}'
        )


        PERCENT=$(
            jq -r \
                '.completion // 0' \
                <<< "$LOCAL_COMPLETION"
        )


        NEED_ITEMS=$(
            jq -r \
                '.needItems // 0' \
                <<< "$LOCAL_COMPLETION"
        )


        printf \
            "\rLocal sync: %s%% | Remaining items: %s   " \
            "$PERCENT" \
            "$NEED_ITEMS"


        if awk \
            "BEGIN {exit !($PERCENT >= 100)}"; then

            break
        fi


        sleep 3

    done


    echo
    echo "Complete."

done


# ============================================================
# DONE
# ============================================================

echo
echo "======================================"
echo " SYNCTHING JOIN COMPLETE"
echo "======================================"
echo
echo "Primary:"
echo "  $PRIMARY_ID"
echo
echo "Folders configured:"


for i in "${!ACCEPTED_IDS[@]}"; do

    echo
    echo "  ${ACCEPTED_LABELS[$i]}"
    echo "    ${ACCEPTED_PATHS[$i]}"

done


echo
echo "Startup configuration is complete."
echo "This secondary device is ready."
