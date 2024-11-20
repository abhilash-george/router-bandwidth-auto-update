#!/bin/bash

LOG_FILE="/tmp/clickhouse.db"
LOG_DIR="/tmp/clickhouse"
ENV_FILE="/home/wifidabba/partner-kit/.env"
ACCESS_POINTS_JSON_FILE="/home/wifidabba/helloworld/access_point_static_ip_list.json"
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
    local bot_token="7170671202:AAHxnM6Nbmjy5MCeiUnI45iefMEqp-uivT4"
    local chat_id="-1002381858257"

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
    for file in "$ENV_FILE" "$ACCESS_POINTS_JSON_FILE" "$LOG_FILE"; do
        if [ ! -f "$file" ]; then
            log_message "ERROR" "Required file not found: $file"
            exit 1
        fi
    done

    if ! jq empty "$ACCESS_POINTS_JSON_FILE" 2>/dev/null; then
        log_message "ERROR" "Invalid JSON format in $ACCESS_POINTS_JSON_FILE"
        exit 1
    fi
}


load_env() {
    set -a
    . "$ENV_FILE"
    set +a

    validate_env "B2B_API_URL"
    validate_env "WD_TOKEN"
    validate_env "DABBA_ID"
    validate_env "WD_NUMBER"
    validate_env "DABBA_LITE_PASSWORD"

    BASE_API_URL="$B2B_API_URL"
    API_URL="$BASE_API_URL/api/dabba/metrics/bandwidth-logs"
    AUTH_TOKEN="$WD_TOKEN"
    base_dabba_id="$DABBA_ID"
    base_dabba_wd_number="$WD_NUMBER"
    lco="${LCO:-wifidabba}"
    access_point_password=$DABBA_LITE_PASSWORD
}

validate_env() {
    eval val=\$$1
    if [ -z "${val}" ]; then
        log_message "ERROR" "Required environment variable $1 is not set"
        exit 1
    fi
}

get_access_point_clients() {
    access_point_ip_address="$1"
    /usr/bin/sshpass -p "$access_point_password" ssh -oHostKeyAlgorithms=+ssh-rsa root@"$access_point_ip_address" '
        for radio in $(iw dev | grep Interface | awk "{print \$2}"); do
            iw dev "$radio" station dump | grep "Station" | cut -d " " -f 2
        done
    '
}

wd_id_mac_mapping() {
    ap_ip=$1
    ap_id=$2
    wd_number=$3
    clients=$(get_access_point_clients "$ap_ip")
    echo "$clients" | while read -r mac; do
        if [ -n "$mac" ]; then
            echo "$mac,$ap_id,$wd_number"
        fi
    done
}

get_connected_devices() {
    declare -a pids=()
    local output=""
    local tempfile=$(mktemp)

    readarray -t data < <(jq -r '.[] | [.ip_address, ._id, .wd_number] | @csv' "$ACCESS_POINTS_JSON_FILE")

    for line in "${data[@]}"; do
        IFS=',' read ap_ip ap_id wd_number <<< "$line"
        ap_ip=$(echo "$ap_ip" | tr -d '"')
        ap_id=$(echo "$ap_id" | tr -d '"')
        wd_number=$(echo "$wd_number" | tr -d '"')
        (wd_id_mac_mapping "$ap_ip" "$ap_id" "$wd_number" >> "$tempfile") &
        pids+=($!)
    done

    for pid in "${pids[@]}"; do
        wait "$pid" 2>/dev/null
    done

    cat "$tempfile"
    rm -f "$tempfile"
}


process_log_file() {
    local log_file=$1
    local devices=$2
    local json_array=""
    local line_count=0

    while IFS=, read -r mac_address ip_address interface download upload total first_seen last_seen; do
        if [ "$ip_address" = "ip" ]; then
            continue
        fi

        local device_info
        device_info=$(printf "%s\n" "$devices" | grep -F "$mac_address" | head -n 1 )
        json_payload=$(cat <<EOF
{
"ip_address" : "$ip_address",
"mac_address" : "$mac_address",
"logged_on" : "$(date +%s)",
"download_in_kb" : "$(echo "$download" | awk '{printf "%.0f", $1 / 1000}')",
"upload_in_kb" : "$(echo "$upload" | awk '{printf "%.0f", $1 / 1000}')",
"total_in_kb" : "$(echo "$total" | awk '{printf "%.0f", $1 / 1000}')",
"interface" : "$interface",
"access_point_id": "$(echo $device_info | awk -F',' '{print $2}')",
"access_point_wd_number": "$(echo $device_info | awk  -F',' '{print $3}')"
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
            rm -f "$log_file"
            rm -f "$LOG_DIR/$FILENAME"
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
    connected_devices="$(get_connected_devices)"
    mkdir -p "$LOG_DIR"
    process_log_file "$LOG_FILE" "$connected_devices"
}

main