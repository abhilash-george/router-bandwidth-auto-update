#!/bin/sh

LOG_FILE="/tmp/clickhouse.db"
LOG_DIR="/tmp/clickhouse"
ENV_FILE="/home/wifidabba/wrtbwmon/.env"
CURRENT_DATE=$(date +"%Y-%m-%d_%H-%M-%S")

log_message() {
    local level=$1
    local message=$2
    logger "[$level]: $CURRENT_DATE = $message"
    send_telegram_alert "$base_dabba_wd_number" "$level" "$message"
}

send_telegram_alert() {
    local dabba_number="$1"
    local level="$2"
    local title="$3"
    local bot_token="$bot_token"
    local chat_id="$chat_id"

    local message="*‼️  \`$title\`*

 *Base Dabba Number*: \`$dabba_number\`
 *Level*: \`$level\`
 *Time*: \`$(date '+%Y-%m-%d %H:%M:%S')\`"

    curl -s -X POST "https://api.telegram.org/bot${bot_token}/sendMessage" \
        -d "chat_id=${chat_id}" \
        -d "text=${message}" \
        -d "parse_mode=Markdown"
}

check_required_files() {
    for file in "$ENV_FILE" "$LOG_FILE"; do
        if [ ! -f "$file" ]; then
            log_message "ERROR" "Required file not found: $file"
            exit 1
        fi
    done
}


load_env() {
    set -a 
    . "$ENV_FILE"
    set +a

    validate_env "B2B_API_URL"
    validate_env "WD_TOKEN"
    validate_env "DABBA_ID"
    validate_env "WD_NUMBER"

    BASE_API_URL="$B2B_API_URL"
    API_URL="$BASE_API_URL/api/dabba/metrics/bandwidth-logs"
    AUTH_TOKEN="$WD_TOKEN"
    base_dabba_id="$DABBA_ID"
    base_dabba_wd_number="$WD_NUMBER"
    lco="${LCO:-wifidabba}"
    bot_token="$BOT_TOKEN"
    chat_id="$CHAT_ID"
}

validate_env() {
    eval val=\$$1
    if [ -z "${val}" ]; then
        log_message "ERROR" "Required environment variable $1 is not set"
        exit 1
    fi
}

process_log_file() {
    local log_file=$1
    local json_array=""
    local line_count=0

    while IFS=, read -r mac_address ip_address interface download upload total first_seen last_seen; do
        if [ "$ip_address" = "ip" ]; then
            continue
        fi

        json_payload=$(cat <<EOF
{
"ip_address" : "$ip_address",
"mac_address" : "$mac_address",
"logged_on" : "$(date +%s)",
"download_in_kb" : "$(echo "$download" | awk '{printf "%.0f", $1 / 1000}')", 
"upload_in_kb" : "$(echo "$upload" | awk '{printf "%.0f", $1 / 1000}')", 
"total_in_kb" : "$(echo "$total" | awk '{printf "%.0f", $1 / 1000}')",
"interface" : "$interface",
"access_point_id": "$base_dabba_id",
"access_point_wd_number": "$base_dabba_wd_number"
}
EOF
)
        if [ -z "$json_array" ]; then
            json_array="$json_payload"
        else
            json_array="$json_array, $json_payload"
        fi

        line_count=$((line_count + 1))
    done < "$log_file"

    if [ -n "$json_array" ]; then
        final_json_payload=$(cat <<EOF
{
    "bandwidthLogs": [
        $json_array
    ],
    "lco": "$lco",
    "base_dabba_id": "$base_dabba_id",
    "base_dabba_wd_number": "$base_dabba_wd_number",
    "database": "clickhouse"
}
EOF
)
        FILENAME="final_json_file_$CURRENT_DATE.json"
        echo "$final_json_payload" > "$LOG_DIR/$FILENAME"

        response=$(curl --location --silent --write-out "%{http_code}" --output /dev/null \
            --header 'Content-Type: application/json' \
            --header "Authorization: $AUTH_TOKEN" \
            --data "@$LOG_DIR/$FILENAME" \
            "$API_URL")

        if [ "$response" -eq 200 ]; then
            logger "[INFO]: $CURRENT_DATE = Successfully sent $line_count lines from file $log_file"
            rm -f "$LOG_DIR/$FILENAME"
            rm -f "$log_file"
        else
            log_message "ERROR"  "Failed to send data for file $log_file with HTTP status $response"
            rm -f "$log_file"
        fi
    else
        log_message "INFO" "No valid data found in $log_file"
    fi
}

main() {
    check_required_files
    load_env
    mkdir -p "$LOG_DIR"
    process_log_file "$LOG_FILE" "$connected_devices"
}

main
    