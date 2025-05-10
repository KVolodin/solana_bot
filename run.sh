#!/bin/bash

cd "$(dirname "$0")"
source ./config.sh

log_error() {
    echo "$(date) - ERROR: $1" >> "$LOG_BOT_FILE"
}

log_warn() {
    echo "$(date) - WARN: $1" >> "$LOG_BOT_FILE"
}

log_info() {
    echo "$(date) - INFO: $1" >> "$LOG_BOT_FILE"
}

send_message() {
    local message=$1
    local remove_keyboard=${2:-false}

    local payload="chat_id=$BOT_ID&text=$message"
    if [[ "$remove_keyboard" == "true" ]]; then
        payload="$payload&reply_markup=$(jq -nc '{remove_keyboard: true}')"
    fi

    res=$(curl -s -X POST "$TELEGRAM_SEND_URL" -d "$payload")

    if [[ $(echo "$res" | jq -r '.ok') != "true" ]]; then
        log_error "Ошибка отправки сообщения: $message"
        return 1
    fi
}

generate_keyboard() {
    local action_text="$1"
    shift
    buttons=""

    for button_text in "$@"; do
        buttons="$buttons, [{\"text\":\"$button_text\"}]"
    done

    keyboard="{\"keyboard\": [${buttons:2}], \"one_time_keyboard\": true}"

    res=$(curl -s -X POST $TELEGRAM_SEND_URL -d chat_id=$BOT_ID -d text="$action_text" -d reply_markup="$keyboard")

    if [[ $(echo "$res" | jq -r '.ok') != "true" ]]; then
        log_error "Ошибка генерации клавиатуры: $keyboard"
    fi
}

set_bot_commands() {
    res=$(curl -s -X POST "https://api.telegram.org/bot${TELEGRAM_TOKEN}/setMyCommands" -H "Content-Type: application/json" -d '{
        "commands": [
            {"command": "update", "description": "Обновить ноду"},
            {"command": "history_update", "description": "Получить историю обновления"},
            {"command": "service", "description": "Сервис"},
            {"command": "catchup", "description": "Проверить синхронизацию"},
            {"command": "monitor_agave", "description": "Проверить синхронизацию"},
            {"command": "validators", "description": "Проверить валидаторов"},
            {"command": "get_log_bot", "description": "Получить логи бота"},
            {"command": "log_service", "description": "Просмотр логов сервиса"},
            {"command": "reboot", "description": "!!! Перезагрузить ноду"}
        ]
    }')

    if [[ $(echo "$res" | jq -r '.ok') != "true" ]]; then
        log_error "Ошибка создания меню"
        return 1
    fi

    send_main_menu
}

send_main_menu() {
    local message+="<b>/update</b> - обновление ноды%0A%0A"
    message+="<b>/history_update</b> - скачать историю обновлений%0A%0A"
    message+="<b>/service</b> - Рестарт/Старт/Стоп/Версия%0A%0A"
    message+="<b>/catchup</b> - проверка синхронизации%0A%0A"
    message+="<b>/monitor_agave</b> - проверка синхронизации%0A%0A"
    message+="<b>/validators</b> - получить список валидаторов%0A%0A"
    message+="<b>/log_service</b> - просмотр логов сервиса%0A%0A"
    message+="<b>/get_log_bot</b> - скачать логи бота%0A%0A"

    if [[ $CLIENT == $CLIENT_FIREDANCER ]]; then
        message+="<b>/get_log_install</b> - скачать логи установки%0A%0A"
    fi
    message+="<b>/reboot</b> - !!! Перезагрузить ноду%0A%0A"

    res=$(curl -s -X POST "$TELEGRAM_SEND_URL" \
        -d chat_id="$BOT_ID" \
        -d text="$message" \
        -d parse_mode="HTML")

    if [[ $(echo "$res" | jq -r '.ok') != "true" ]]; then
        log_error "Ошибка создания меню"
        return 1
    fi

    res=$(curl -s -X POST "$TELEGRAM_SEND_URL" \
        -d chat_id="$BOT_ID" \
        -d text="Выберите одну из команд" \
        -d reply_markup='{"remove_keyboard": true}')

    if [[ $(echo "$res" | jq -r '.ok') != "true" ]]; then
        log_error "Ошибка обнуления клавиатуры"
        return 1
    fi
}

send_version_menu() {
    if [[ -z "$GITHUB_TOKEN" ]]; then
        send_message "🔧 Укажите версию вручную без v, переменная GITHUB_TOKEN не задана."
        return
    fi

    mapfile -t versions < <(get_versions)
    generate_keyboard "Выберите версию для обновления:" "${versions[@]}"
}

send_file() {
    local file_path="$1"

    if [[ ! -f "$file_path" ]]; then
        send_message "Файл '$file_path' не найден!" true
        return 1
    fi

    res=$(curl -X POST "https://api.telegram.org/bot${TELEGRAM_TOKEN}/sendDocument" \
        -F "chat_id=${BOT_ID}" \
        -F "document=@${file_path}")

    if [[ $(echo "$res" | jq -r '.ok') != "true" ]]; then
        log_error "Ошибка при отправке файла: ${file_path}."
        return 1
    fi
}

get_updates() {
    local offset=$1
    curl -s -X GET "https://api.telegram.org/bot${TELEGRAM_TOKEN}/getUpdates?offset=${offset}"
}

get_versions() {
    repo=""
    if [[ $CLIENT == $CLIENT_FIREDANCER ]]; then
        repo="firedancer-io/firedancer"
    elif [[ $CLIENT == $CLIENT_AGAVE ]]; then
        repo="anza-xyz/agave"
    else
        log_error "Задан неправильный клиент"
        return 1
    fi
    api_url="https://api.github.com/repos/$repo/tags"

    curl -s -H "Authorization: token $GITHUB_TOKEN" "$api_url" | jq -r '.[0:5] | .[] | .name' | sed 's/^v//'
}

#States
STATE_MAIN_MENU="main_menu"

STATE_SERVICE="service"
STATE_SERVICE_UNSAFE="service_unsafe"

STATE_UPDATE="update"
STATE_UPDATE_2="update_2"

STATE_LOG="log"
STATE_LOG_2="log_2"

STATE_REBOOT="reboot"

CURRENT_STATE=$STATE_MAIN_MENU

update() {
    local command="$1"
    case "$command" in
        "/start")
            send_message "Привет! Я бот, который умеет обновлять ноды Solana"
            send_main_menu
            ;;

        "/update")
            CURRENT_STATE=$STATE_UPDATE
            send_version_menu
            ;;

        "/service")
            CURRENT_STATE=$STATE_SERVICE
            generate_keyboard "Выберите действие" "start" "stop" "restart" "version"
            ;;

        "/history_update")
            send_file "$UPDATE_HISTORY_FILE"
            ;;

        "/get_log_bot")
            send_file "$LOG_BOT_FILE"
            ;;

        "/get_log_install")
            send_file "$INSTALL_LOG_FILE"
            ;;

        "/catchup")
            catchup
            ;;

        "/monitor_agave")
            monitor_agave
            ;;

        "/validators")
            validators
            ;;

        "/log_service")
            CURRENT_STATE=$STATE_LOG
            generate_keyboard "Выберите лог левел" "ERR" "WARNING" "INFO"
            ;;

        "/reboot")
            CURRENT_STATE=$STATE_REBOOT
            generate_keyboard "Вы уверены?" "Yes" "No"
            ;;

        *)
            case "$CURRENT_STATE" in
                "$STATE_UPDATE" | "$STATE_UPDATE_2")
                    handle_update "$command"
                    ;;

                "$STATE_LOG" | "$STATE_LOG_2")
                    handle_log "$command"
                    ;;

                "$STATE_SERVICE" | "$STATE_SERVICE_UNSAFE")
                    handle_service "$command"
                    ;;

                "$STATE_REBOOT")
                    handle_reboot "$command"
                    ;;

                *)
                    send_message "Неизвестная команда: $command"
                    ;;
            esac
            ;;

    esac
}

validators() {
    output=$(${SUDO_CMD} solana validators | awk '/Stake By Version:/,0' 2>&1)
    if [[ $? -eq 0 ]]; then
        echo "$output" | while IFS= read -r line; do send_message "$line" true; done
    else
        send_message "Ошибка: $output" true
    fi
}

catchup() {
    output=$(timeout -k 2 10 ${SUDO_CMD} solana catchup ${KEY_PAIR_PATH} http://127.0.0.1:8899/ 2>&1)
    if [[ $? -eq 0 ]]; then
        send_message "$output" true
        if [[ $output =~ us:([0-9]+) ]]; then us_slot=${BASH_REMATCH[1]}; fi
        if [[ $output =~ them:([0-9]+) ]]; then them_slot=${BASH_REMATCH[1]}; fi
        send_message "Разница между слотами: $((us_slot - them_slot))" true
    else
        send_message "Ошибка: $output" true
    fi
}

declare -g current_service_action=""
handle_service() {
    local command=$1

    case "${CURRENT_STATE}" in
        "$STATE_SERVICE")
            case "$command" in
                start|stop|restart)
                    CURRENT_STATE=$STATE_SERVICE_UNSAFE
                    current_service_action=$command
                    generate_keyboard "Вы уверены?" "Yes" "No"
                    ;;
                *)
                    if [[ "$command" == "version" ]]; then
                        version=$(curl -s http://127.0.0.1:8899 -X POST -H "Content-Type: application/json" \
                                -d '{"jsonrpc":"2.0", "id":1, "method":"getVersion"}' | jq -r '.result."solana-core"')
                        send_message "Текущая версия: $version" true
                    else
                        send_main_menu
                    fi
                    ;;
            esac
            ;;

        "$STATE_SERVICE_UNSAFE")
            if [[ "$command" == "Yes" ]]; then
                ${SUDO_CMD} systemctl ${current_service_action} ${SERVICE}
            else
                send_main_menu
            fi
            ;;
    esac
}

declare -g current_version=""
handle_update() {
    local command=$1

    case "${CURRENT_STATE}" in
        "$STATE_UPDATE")
            if [[ $command =~ ^([0-9]+)\.([0-9]+)\.([0-9]+)$ ]]; then
                CURRENT_STATE=$STATE_UPDATE_2
                current_version=$command
                generate_keyboard "Выберите max-delinquent-stake" "5" "10" "15" "20" "25"
            else
                send_message "Неправильно задана версия"
                send_version_menu
            fi
            ;;

        "$STATE_UPDATE_2")
            if [[ "$command" =~ ^[0-9]+$ ]] && ((command >= 0 && command <= 100)); then
                update_version "$current_version" "$command"
            else
                send_message "max-delinquent-stake может быть в диапазоне от 0 до 100"
                generate_keyboard "Выберите max-delinquent-stake" "5" "10" "15" "20" "25"
            fi
            ;;
    esac
}

declare -g current_log_level="ERR"
handle_log() {
    local command=$1

    case "${CURRENT_STATE}" in
        "${STATE_LOG}")
            current_log_level=$command
            generate_keyboard "Выберите количество логов" "1" "2" "5" "10" "20"
            CURRENT_STATE=$STATE_LOG_2
            ;;

        "${STATE_LOG_2}")
            count=$command
            logs=$(${SUDO_CMD} journalctl -u ${SERVICE} --no-pager -n ${JOURNAL_COUNT} | grep " ${current_log_level} " | tail -n ${count})
            if [[ -z "$logs" ]]; then
                send_message "Логи не найдены" true
            else
                send_message "Последние ${count} строк логов уровня ${current_log_level}:" true
                echo "$logs" | while IFS= read -r line; do send_message "$line"; done
            fi
            ;;
    esac
}

handle_reboot() {
    local command=$1

    case "$command" in
        "Yes")
            send_message "Перезагружаю систему..." true
            ${SUDO_CMD} reboot || send_message "Ошибка: не удалось перезагрузить систему"
            ;;
        "No")
            ;;
        *)
            send_main_menu
            ;;
    esac
}

monitor_agave() {
    output=$(${SUDO_CMD} timeout 1 agave-validator --ledger ${LEDGER_FOLDER} monitor 2>&1)
    if ! echo "$output" | grep -q "Processed Slot"; then
        send_message "⏳ Нода запускается: $output" true
        return 0
    fi
    health=$(echo "$output" | grep -oP '\| \K([0-9]+ slots behind|unhealthy|ok)' | head -n1)

    case "$health" in
        unhealthy)
            send_message "⚠️ Нода unhealthy" true
            ;;
        *"slots behind")
            delay=$(echo "$health" | grep -oP '^\d+')
            if [[ -n "$delay" ]]; then
                send_message "⚠️ Нода отстаёт на $delay слотов" true
            else
                send_message "⚠️ Нода отстаёт, но не удалось определить на сколько" true
            fi
            ;;
        ok|"")
            trimmed=$(echo "$output" | grep "Processed Slot" | tail -n 1)
            send_message "🟢 healthy: $trimmed" true
            ;;
        *)
            send_message "⚠️ Неизвестный статус ноды: $health" true
            ;;
    esac
}


update_version() {
    local current_version=$1
    local max_delinquent=$2

    TELEGRAM=1 ./private/update.sh "$current_version" "$max_delinquent"
}

run_loop() {
    if [[ -f "$ID_FILE" ]]; then
        last_update_id=$(cat "$ID_FILE")
    else
        last_update_id=0
    fi

    while true; do
        updates=$(get_updates $last_update_id)

        if [[ $(echo "$updates" | jq -r '.ok') == "false" ]]; then
            sleep 1
            continue
        fi

        results=$(echo "$updates" | jq -c '.result[]')

        for update in $results; do
            update_id=$(echo "$update" | jq -r '.update_id')

            if [ -z "$update_id" ] || [ "$update_id" -le "$last_update_id" ]; then
                continue
            fi

            last_update_id=$update_id
            echo "$last_update_id" > "$ID_FILE"

            command=$(echo $update | jq -r '.message.text')
            update $command
        done

        sleep 1
    done
}

main() {
    set_bot_commands

    run_loop
}

main "$@"
