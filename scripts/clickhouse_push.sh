#!/bin/sh

LOG_FILE="/tmp/clickhouse.db"
LOG_DIR="/tmp/clickhouse"
ENV_FILE="/home/wifidabba/wrtbwmon/.env"
CURRENT_DATE=$(date +"%Y-%m-%d_%H-%M-%S")

if [ -f "$ENV_FILE" ]; then
    set -a 
    . "$ENV_FILE"
    set +a
else
    echo "Error: .env file not found in $ENV_FILE!"
    exit 1
fi
BASE_API_URL="$B2B_API_URL"
API_URL="$BASE_API_URL/api/dabba/metrics/bandwidth-logs"
AUTH_TOKEN="$WD_TOKEN"
base_dabba_id="$DABBA_ID"
base_dabba_wd_number="$WD_NUMBER"
lco="${LCO:-wifidabba}"

process_log_file() {
    local log_file=$1
    local json_array=""
    local line_count=0

    while IFS=, read -r mac_address ip_address interface download upload total first_seen last_seen; do
        if [ "$ip_address" = "ip" ]; then
            continue
        fi

        if [ "$total" -gt 1000000000 ]; then
            mkdir -p "/home/wifidabba/wrtbwmon_monitoring_logs"
            cp "$log_file" "/home/wifidabba/wrtbwmon_monitoring_logs/log_file_greater_than_1GB_$CURRENT_DATE.db"
        fi

        json_payload=$(cat <<EOF
{
"ip_address" : "$ip_address",
"mac_address" : "$mac_address",
"logged_on" : "$(date +%s)",
"download_in_kb" : "$(echo "$download" | awk '{printf "%.0f", $1 / 1000}')", 
"upload_in_kb" : "$(echo "$upload" | awk '{printf "%.0f", $1 / 1000}')", 
"total_in_kb" : "$(echo "$total" | awk '{printf "%.0f", $1 / 1000}')",
"interface" : "$interface"
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
            logger -t Clickhouse_Push "Successfully sent $line_count lines from file $log_file"
            rm -f "$log_file"
            rm -f "$LOG_DIR/$FILENAME"
        else
            echo "Failed to send data for file $log_file with HTTP status $response"
        fi
    else
        echo "No valid data found in $log_file"
    fi
}

# Check if the wrtbwmon log file exists.
if [ -f "$LOG_FILE" ]; then
    mkdir -p "$LOG_DIR"
    process_log_file "$LOG_FILE"
else
    logger -t clickhouse_push "wrtbwmon dump file not found."
fi

