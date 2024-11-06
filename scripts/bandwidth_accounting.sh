#!/bin/sh

log_message() {
    logger -t bandwidth_accounting.sh "$1"
}

log_message "Looking for changes in code"
cd /home/wifidabba/clickhouse && git checkout Jadhav-Properties && git pull

log_message "setting up wrtbwmon db"
/usr/sbin/wrtbwmon setup /tmp/clickhouse.db

log_message "Updating wrtbwmon db"
/usr/sbin/wrtbwmon update /tmp/clickhouse.db

log_message "Starting pusing to Clickhouse database"
cd /home/wifidabba/clickhouse/scripts && ./clickhouse_push.sh 2>&1 | logger -t clickhouse_push.sh

