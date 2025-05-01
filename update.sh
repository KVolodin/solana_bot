#!/bin/bash
set -eo pipefail

source ./config.sh

TELEGRAM_EDIT_URL="https://api.telegram.org/bot$TELEGRAM_TOKEN/editMessageText"

send_message_curl() {
    local message=$1
    local url="https://api.telegram.org/bot$TELEGRAM_TOKEN/sendMessage"
    echo $(curl -s -X POST $url -d chat_id=$CHAT_ID -d text="$message")
}

edit_message_curl() {
    local message=$1
    local message_id=$2
    local url="https://api.telegram.org/bot$TELEGRAM_TOKEN/editMessageText"
    echo $(curl -s -X POST $url -d chat_id=$CHAT_ID -d "message_id=$message_id" -d text="$message")
}

delete_message() {
    local message_id=$1
    local url="https://api.telegram.org/bot$TELEGRAM_TOKEN/deleteMessage"

    response=$(curl -s -X POST $url -d chat_id=$CHAT_ID -d message_id=$message_id)

    if [[ $(echo "$response" | jq -r '.ok') != "true" ]]; then
        echo "Ошибка при удалении сообщения $message_id"
    fi
}

animate() {
    local message=$1
    local message_id=$2
    local frames=("◢" "◣" "◤" "◥")

    while true; do
        for frame in "${frames[@]}"; do
            edit_message_curl "${message} $frame" "$message_id" > /dev/null
            sleep 0.5
        done
    done
}

run_with_animation() {
    local command=$1
    local message=$2

    message_id=$(send_message_curl "$message" | jq '.result.message_id')

    animate "$message" "$message_id" &
    animation_pid=$!

    $command
    local exit_code=$?

    kill $animation_pid
    delete_message $message_id

    return $exit_code
}


output_message() {
    local message=$1
    if [ "$TELEGRAM" == "1" ]; then
        response=$(send_message_curl "$message")
        if [[ $(echo "$response" | jq -r '.ok') != "true" ]]; then
            echo "Ошибка отправки сообщения: $message"
            return 1
        fi
    else
        echo "$message"
    fi
}

if [ -z "$1" ]; then
    VERSION_EXAMPLE=""
    if [[ $CLIENT == $CLIENT_FIREDANCER ]]; then
        VERSION_EXAMPLE="0.403.20113"
    elif [[ $CLIENT == $CLIENT_AGAVE ]]; then
        VERSION_EXAMPLE="2.0.13"
    fi
    output_message "Укажите версию для обновления, например ${VERSION_EXAMPLE}"
    exit 1
fi

VERSION="v${1}"
MAX_DELINQUENT_STAKE=${2:-5}

format_duration() {
    local duration=$1
    local hours=$((duration / 3600))
    local minutes=$(((duration % 3600) / 60))
    local seconds=$((duration % 60))
    echo "${hours}ч:${minutes}м:${seconds}с"
}

wait_for_restart_and_restart() {
    local sudo_cmd=""
    if [ "${USE_SUDO}" = "true" ]; then
        sudo_cmd="sudo"
    fi
    ${sudo_cmd} agave-validator --ledger ${LEDGER_FOLDER} wait-for-restart-window --max-delinquent-stake $MAX_DELINQUENT_STAKE > /dev/null 2>&1 && \
    ${sudo_cmd} systemctl restart ${SERVICE}
}

install_firedancer_deps() {
    ./deps.sh fetch >> "$INSTALL_LOG_FILE" 2>&1
    ./deps.sh check >> "$INSTALL_LOG_FILE" 2>&1
    ./deps.sh install >> "$INSTALL_LOG_FILE" 2>&1
}

make_firedancer(){
    make -j fdctl solana >> "$INSTALL_LOG_FILE" 2>&1
    return $?
}

install_firedancer() {
    INSTALL_FD_DIR="${INSTALL_FD_DIR:-$PWD/firedancer}"
    local repo_url="https://github.com/firedancer-io/firedancer"
    local firedancer_bin="${INSTALL_FD_DIR}/build/native/gcc/bin/fdctl"

    if [[ -x "$firedancer_bin" ]]; then
        current_version=$("$firedancer_bin" version 2>/dev/null | awk '{print $1}')
        clean_version=${VERSION#v}

        if [[ "$current_version" == "$clean_version" ]]; then
            output_message "Версии совпадают, установка не требуется" | tee -a "$INSTALL_LOG_FILE"
            return 0
        fi
    fi

    rm -rf $INSTALL_LOG_FILE
    if [[ ! -d "$INSTALL_FD_DIR/.git" ]]; then
        output_message "Клонируем репозиторий в $INSTALL_FD_DIR" | tee -a "$INSTALL_LOG_FILE"
        git clone  --recurse-submodules "$repo_url" "$INSTALL_FD_DIR" >> "$INSTALL_LOG_FILE" 2>&1
        if [[ $? -ne 0 ]]; then
            output_message "Ошибка: не удалось клонировать репозиторий" | tee -a "$INSTALL_LOG_FILE"
            return 1
        fi
    fi

    cd "$INSTALL_FD_DIR" || return 1

    git submodule sync
    git submodule update --init --recursive >> "$INSTALL_LOG_FILE" 2>&1
    if [[ $? -ne 0 ]]; then
        output_message "Ошибка при обновлении подмодулей. Попробуем пересинхронизировать agave..." | tee -a "$INSTALL_LOG_FILE"

        git submodule deinit -f agave >> "$INSTALL_LOG_FILE" 2>&1
        rm -rf .git/modules/agave agave
        git submodule update --init --recursive >> "$INSTALL_LOG_FILE" 2>&1

        if [[ $? -ne 0 ]]; then
            output_message "Ошибка: не удалось восстановить подмодуль agave." | tee -a "$INSTALL_LOG_FILE"
            return 1
        fi
    fi
    git fetch origin >> "$INSTALL_LOG_FILE" 2>&1
    git checkout "$VERSION" >> "$INSTALL_LOG_FILE" 2>&1
    if [[ $? -ne 0 ]]; then
        output_message "Ошибка: не удалось переключиться на версию $VERSION" | tee -a "$INSTALL_LOG_FILE"
        return 1
    fi

    if [ "$TELEGRAM" == "1" ]; then
        run_with_animation install_firedancer_deps "Установка зависимостей" || return 1
        run_with_animation make_firedancer "Запуск сборки" || return 1
    else
        output_message "Установка зависимостей" | tee -a "$INSTALL_LOG_FILE"
        install_firedancer_deps

        output_message "Запуск сборки" | tee -a "$INSTALL_LOG_FILE"
        make_firedancer
    fi

    if [[ $? -ne 0 ]]; then
        output_message "Ошибка: сборка не удалась" | tee -a "$INSTALL_LOG_FILE"
        return 1
    fi

    cd -

    FDCTL_VERSION=$("${firedancer_bin}" --version 2>/dev/null | awk '{print $1}')
    CLEAN_VERSION=${VERSION#v}

    if [[ "$FDCTL_VERSION" != "$CLEAN_VERSION" ]]; then
        output_message "Ошибка: версии не совпадают: текущая=$FDCTL_VERSION, ожидается=$CLEAN_VERSION" | tee -a "$INSTALL_LOG_FILE"
        tail -n 10 "$INSTALL_LOG_FILE"
        return 1
    fi

    return 0
}

install_agave() {
    sh -c "$(curl -sSfL https://release.anza.xyz/$VERSION/install)"
}

save_history() {
    echo "{\"date\": \"$(date)\", \"version\": \"${VERSION}\", \"client\": \"$CLIENT\", \"total_duration\": \"$(format_duration $TOTAL_DURATION)\", \"max-delinquent-stake\": \"$MAX_DELINQUENT_STAKE\"}" >> ${UPDATE_HISTORY_FILE}
}

output_message "Начата установка ${CLIENT} версии: ${VERSION}"

START_TIME=$(date +%s)

if [[ $CLIENT == $CLIENT_FIREDANCER ]]; then
    if ! install_firedancer; then
        output_message "Ошибка: установка Firedancer не удалась."
        exit 1
    fi

elif [[ $CLIENT == $CLIENT_AGAVE ]]; then
    install_agave
else
    output_message "Задан неправльный клиент"
    return 1
fi

if [ $? -eq 0 ]; then
    INSTALL_TIME=$(date +%s)
    INSTALL_DURATION=$((INSTALL_TIME - START_TIME))
    output_message "Установка $CLIENT $VERSION завершена за $(format_duration $INSTALL_DURATION)."

    if [ "$TELEGRAM" == "1" ]; then
        run_with_animation wait_for_restart_and_restart "Ожидание окна перезапуска валидатора($MAX_DELINQUENT_STAKE)"
    else
        output_message "Ожидание окна перезапуска валидатора (max-delinquent-stake: $MAX_DELINQUENT_STAKE)..."
        wait_for_restart_and_restart
    fi

    if [ $? -eq 0 ]; then
        END_TIME=$(date +%s)
        TOTAL_DURATION=$((END_TIME - START_TIME))
        output_message "#update: $CLIENT обновлен до версии ${VERSION}, дата: $(date). общее время: $(format_duration $TOTAL_DURATION)."
        save_history

    else
        output_message "Ошибка перезапуска службы."
    fi
else
    output_message "Ошибка установки $CLIENT версии $VERSION."
    exit 1
fi
