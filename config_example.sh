# --- Enum for Clients ---
CLIENT_FIREDANCER="firedancer"
CLIENT_AGAVE="agave"

# --- Select Client ---
CLIENT=$CLIENT_FIREDANCER  # Change this to CLIENT_AGAVE if you want to use Agave client

LOGS_DIR="$PWD/logs"
if [[ ! -d "$LOGS_DIR" ]]; then
    mkdir -p "$LOGS_DIR"
fi

# --- Required Variables ---
TELEGRAM_TOKEN=""       # Set your Telegram token here, ask from @BotFather
CHAT_ID=""              # Set your Telegram chat ID here, ask from @userinfobot
SERVICE="sol.service"
LEDGER_FOLDER="/mnt/ledger/"
USE_SUDO=true

# --- Logs ---
INSTALL_LOG_FILE="${LOGS_DIR}/install.log"
LOG_BOT_FILE="${LOGS_DIR}/bot.log"
UPDATE_HISTORY_FILE="${LOGS_DIR}/history.log"

KEY_PAIR_PATH="$PWD/validator-keypair.json"
GITHUB_TOKEN=""         # GitHub token for get versions

# --- Optional Variables ---
JOURNAL_COUNT=100000
INSTALL_FD_DIR="$PWD/firedancer"
