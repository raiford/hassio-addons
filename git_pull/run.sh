#!/bin/bash

#### config ####

CONFIG_PATH=/data/options.json

DEPLOYMENT_KEY=$(jq --raw-output ".deployment_key[]" $CONFIG_PATH)
DEPLOYMENT_KEY_PROTOCOL=$(jq --raw-output ".deployment_key_protocol" $CONFIG_PATH)
DEPLOYMENT_USER=$(jq --raw-output ".deployment_user" $CONFIG_PATH)
DEPLOYMENT_PASSWORD=$(jq --raw-output ".deployment_password" $CONFIG_PATH)
REPOSITORY=$(jq --raw-output '.repository' $CONFIG_PATH)
AUTO_RESTART=$(jq --raw-output '.auto_restart' $CONFIG_PATH)
REPEAT_ACTIVE=$(jq --raw-output '.repeat.active' $CONFIG_PATH)
REPEAT_INTERVAL=$(jq --raw-output '.repeat.interval' $CONFIG_PATH)
################

#### functions ####
function add-ssh-key {
    echo "Start adding SSH key"
    mkdir -p ~/.ssh

    (
        echo "Host *"
        echo "    StrictHostKeyChecking no"
    ) > ~/.ssh/config

    echo "Setup deployment_key on id_${DEPLOYMENT_KEY_PROTOCOL}"
    while read -r line; do
        echo "$line" >> "${HOME}/.ssh/id_${DEPLOYMENT_KEY_PROTOCOL}"
    done <<< "$DEPLOYMENT_KEY"

    chmod 600 "${HOME}/.ssh/config"
    chmod 600 "${HOME}/.ssh/id_${DEPLOYMENT_KEY_PROTOCOL}"
}

function git-clone {
    # create backup
    BACKUP_LOCATION="/tmp/config-$(date +%Y-%m-%d_%H-%M-%S)"
    echo "Backup configuration to $BACKUP_LOCATION"
    
    mkdir "${BACKUP_LOCATION}" || { echo "[Error] Creation of backup directory failed"; exit 1; }
    cp -rf /config/* "${BACKUP_LOCATION}" || { echo "[Error] Copy files to backup directory failed"; exit 1; }
    
    # remove config folder content
    rm -rf /config/{,.[!.],..?}* || { echo "[Error] Clearing /config failed"; exit 1; }

    # git clone
    echo "Start git clone"
    git clone "$REPOSITORY" /config || { echo "[Error] Git clone failed"; exit 1; }

    # try to copy non yml files back
    cp "${BACKUP_LOCATION}" "!(*.yaml)" /config 2>/dev/null

    # try to copy secrets file back
    cp "${BACKUP_LOCATION}/secrets.yaml" /config 2>/dev/null
}

function check-ssh-key {
if [ -n "$DEPLOYMENT_KEY" ]; then
    echo "Check SSH connection"
    IFS=':' read -ra GIT_URL_PARTS <<< "$REPOSITORY"
    # shellcheck disable=SC2029
    if ! ssh -T -o "BatchMode=yes" "${GIT_URL_PARTS[0]}"
    then
        echo "Valid SSH connection for ${GIT_URL_PARTS[0]}"
    else
        echo "No valid SSH connection for ${GIT_URL_PARTS[0]}"
        add-ssh-key
    fi
fi
}

function setup-user-password {
if [ ! -z "$DEPLOYMENT_USER" ]; then
    cd /config || return
    echo "[Info] setting up credential.helper for user: ${DEPLOYMENT_USER}"
    git config --system credential.helper 'store --file=/tmp/git-credentials'

    # Extract the hostname from repository
    h="$REPOSITORY"

    # Extract the protocol
    proto=${h%%://*}

    # Strip the protocol
    h="${h#*://}"

    # Strip username and password from URL
    h="${h#*:*@}"
    h="${h#*@}"

    # Strip the tail of the URL
    h=${h%%/*}

    # Format the input for git credential commands
    cred_data="\
protocol=${proto}
host=${h}
username=${DEPLOYMENT_USER}
password=${DEPLOYMENT_PASSWORD}
"

    # Use git commands to write the credentials to ~/.git-credentials
    echo "[Info] Saving git credentials to /tmp/git-credentials"
    git credential fill | git credential approve <<< "$cred_data"
fi
}

function git-synchronize {
    if git rev-parse --is-inside-git-dir &>/dev/null
    then
        echo "git repository exists, start pulling"
        OLD_COMMIT=$(git rev-parse HEAD)
        git pull || { echo "[Error] Git pull failed"; exit 1; }
    else
        echo "git repostory doesn't exist"
        git-clone
    fi
}

function validate-config {
    echo "[Info] Check if something is changed"
    if [ "$AUTO_RESTART" == "true" ]; then
        # Compare commit ids & check config
        NEW_COMMIT=$(git rev-parse HEAD)
        if [ "$NEW_COMMIT" != "$OLD_COMMIT" ]; then
            echo "[Info] check Home-Assistant config"
            if hassio homeassistant check; then
                echo "[Info] restart Home-Assistant"
                hassio homeassistant restart 2&> /dev/null
            else
                echo "[Error] invalid config!"
            fi
        else
            echo "[Info] Nothing has changed."
        fi
    fi
}

###################

#### Main program ####
cd /config || { echo "[Error] Failed to cd into /config"; exit 1; }
setup-user-password
while true; do
    check-ssh-key
    git-synchronize
    validate-config
     # do we repeat?
    if [ -z "$REPEAT_ACTIVE" ]; then
        exit 0
    fi
    sleep "$REPEAT_INTERVAL"
done

###################
