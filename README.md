# Solana Node Update Bot

Этот бот предназначен для обновления нод Solana и управления сервисами через команды в Telegram.

## Требования

- Telegram-бот с токеном, полученным от BotFather
- Установленный `curl`, `jq` и `git` на сервере
- Конфигурационный файл `config.sh` для указания переменных
- GitHub токен для получения версий из репозитория

## Настройка

1. Склонируйте репозиторий на сервер.

2. Отредактируйте файл `config_example.sh` и сохраните его под именем `config.sh`.

3. Создайте сессию в скрине screen -S solana_bot

4. Запустите скрипт ./run.sh и отключитесь от скрина ctrl + A + D

5. Можно добавить в крон `crontab -e` -> `@reboot sleep 60 && screen -dmS update_bot /path/run.sh`
