#!/bin/bash
set -eo pipefail

source ./config.sh

if [ -z "$1" ]; then
    VERSION_EXAMPLE=""
    if [[ $CLIENT == $CLIENT_FIREDANCER ]]; then
        VERSION_EXAMPLE="0.403.20113"
    elif [[ $CLIENT == $CLIENT_AGAVE ]]; then
        VERSION_EXAMPLE="2.0.13"
    fi
    echo "Укажите версию для обновления, например ${VERSION_EXAMPLE}"
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

install_firedancer() {
    INSTALL_FD_DIR="${INSTALL_FD_DIR:-$PWD/firedancer}"
    local repo_url="https://github.com/firedancer-io/firedancer"
    local firedancer_bin="${INSTALL_FD_DIR}/build/native/gcc/bin/fdctl"

    if [[ -x "$firedancer_bin" ]]; then
        current_version=$("$firedancer_bin" --version 2>/dev/null | awk '{print $1}')
        clean_version=${VERSION#v}

        if [[ "$current_version" == "$clean_version" ]]; then
            return 0
        fi
    fi

    rm -rf $INSTALL_LOG_FILE
    if [[ ! -d "$INSTALL_FD_DIR/.git" ]]; then
        echo "Клонируем репозиторий в $INSTALL_FD_DIR" | tee -a "$INSTALL_LOG_FILE"
        git clone  --recurse-submodules "$repo_url" "$INSTALL_FD_DIR" >> "$INSTALL_LOG_FILE" 2>&1
        if [[ $? -ne 0 ]]; then
            echo "Ошибка: не удалось клонировать репозиторий" | tee -a "$INSTALL_LOG_FILE"
            return 1
        fi
    fi

    cd "$INSTALL_FD_DIR" || return 1

    git submodule update --init --recursive >> "$INSTALL_LOG_FILE" 2>&1
    git fetch origin >> "$INSTALL_LOG_FILE" 2>&1
    git checkout "$VERSION" >> "$INSTALL_LOG_FILE" 2>&1
    if [[ $? -ne 0 ]]; then
        echo "Ошибка: не удалось переключиться на версию $VERSION" | tee -a "$INSTALL_LOG_FILE"
        return 1
    fi

    echo "Установка зависимостей" | tee -a "$INSTALL_LOG_FILE"
    ./deps.sh fetch >> "$INSTALL_LOG_FILE" 2>&1
    ./deps.sh check >> "$INSTALL_LOG_FILE" 2>&1
    ./deps.sh install >> "$INSTALL_LOG_FILE" 2>&1

    echo "Запуск сборки" | tee -a "$INSTALL_LOG_FILE"
    make -j fdctl solana >> "$INSTALL_LOG_FILE" 2>&1
    if [[ $? -ne 0 ]]; then
        echo "Ошибка: сборка не удалась" | tee -a "$INSTALL_LOG_FILE"
        return 1
    fi

    cd -

    FDCTL_VERSION=$("${firedancer_bin}" --version 2>/dev/null | awk '{print $1}')
    CLEAN_VERSION=${VERSION#v}

    if [[ "$FDCTL_VERSION" == "$CLEAN_VERSION" ]]; then
        echo "Успешная установка Firedancer версии $FDCTL_VERSION" | tee -a "$INSTALL_LOG_FILE"
    else
        echo "Ошибка: версии не совпадают (FDCTL=$FDCTL_VERSION, ОЖИДАЕТСЯ=$CLEAN_VERSION)" | tee -a "$INSTALL_LOG_FILE"
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

echo "Обновление ${CLIENT} до версии ${VERSION}..."

START_TIME=$(date +%s)

if [[ $CLIENT == $CLIENT_FIREDANCER ]]; then
    install_firedancer

elif [[ $CLIENT == $CLIENT_AGAVE ]]; then
    install_agave
else
    echo "Задан неправльный клиент"
    return 1
fi

if [ $? -eq 0 ]; then
    INSTALL_TIME=$(date +%s)
    INSTALL_DURATION=$((INSTALL_TIME - START_TIME))
    echo "Обновление $CLIENT $VERSION завершено за $(format_duration $INSTALL_DURATION)."

    echo "Ожидание окна перезапуска валидатора (max-delinquent-stake: $MAX_DELINQUENT_STAKE)..."
    wait_for_restart_and_restart

    if [ $? -eq 0 ]; then
        END_TIME=$(date +%s)
        TOTAL_DURATION=$((END_TIME - START_TIME))
        echo "#update: $CLIENT обновлен до версии ${VERSION}, дата: $(date). общее время: $(format_duration $TOTAL_DURATION)."
        save_history

    else
        echo "Ошибка перезапуска службы."
    fi
else
    echo "Ошибка установки $CLIENT версии $VERSION."
    exit 1
fi
