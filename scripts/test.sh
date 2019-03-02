#!/bin/bash
set -e
CWD=$(pwd)
SCRIPT_PID=$$

# Testing using golang
cd "$(dirname $0)/../golang"
echo "Running tests with coverage..."
make coverage
echo "OK"

# Testing using external tool
# Setup
CACHE_ADDRESS="127.0.0.1:28001"
CONTROLLER_ADDRESS="127.0.0.1:28000"
PROXY_ADDRESS="127.0.0.1:28088"
REDIS_ADDRESS="127.0.0.1:6379"
ASSET_URL="http://game-a.granbluefantasy.jp/assets/font/basic_alphabet.woff"
BIN_DIR="/tmp"
BIN_NAME="gbf-proxy-$(date +%s)"
BIN_EXEC="$BIN_DIR/$BIN_NAME"

echo "Building binary..."
go build -race -o "$BIN_EXEC" -v

cleanup() {
    killall $BIN_NAME
    [ -e "$BIN_EXEC" ] && rm $BIN_EXEC
    cd "$CWD"
}
trap cleanup EXIT


run() {
    $BIN_DIR/$BIN_NAME $@
}

request() {
    curl -fsSL -x http://$PROXY_ADDRESS $@
}

echo "Spinning up cache service at $CACHE_ADDRESS..."
run cache $CACHE_ADDRESS -r $REDIS_ADDRESS 2> /dev/null &
CACHE_PID=$!
sleep 1

echo "Spinning up controller service at $CONTROLLER_ADDRESS..."
run controller $CONTROLLER_ADDRESS -c $CACHE_ADDRESS -w example.org:80 --web-hostname example.org 2> /dev/null &
CONTROLLER_PID=$!
sleep 1

echo "Spinning up proxy service at $PROXY_ADDRESS..."
run proxy $PROXY_ADDRESS $CONTROLLER_ADDRESS 2> /dev/null &
PROXY_PID=$!
sleep 1

sleep 3
pkill -0 -P $CACHE_PID > /dev/null 2>&1 || (echo "Cache service fails to run!" >&2 && exit 1)
pkill -0 -P $CONTROLLER_PID > /dev/null 2>&1 || (echo "Controller service fails to run!" >&2 && exit 1)
pkill -0 -P $PROXY_PID > /dev/null 2>&1 || (echo "Proxy service fails to run!" >&2 && exit 1)

# Test game server
printf "Testing game server... "
request game.granbluefantasy.jp | grep -q "グランブルーファンタジー" && echo "OK" || (echo "FAIL!" && exit 1)
# Test game assets server
printf "Testing game assets server... "
request $ASSET_URL > /dev/null && echo "OK" || (echo "FAIL!" && exit 1)
# Test game assets caching
printf "Testing game assets caching... "
request $ASSET_URL > /dev/null && echo "OK" || (echo "FAIL!" && exit 1)
# Test static web
printf "Testing static web... "
request example.org | grep -q "Example Domain" && echo "OK" || (echo "FAIL!" && exit 1)
# Test forbidden
printf "Testing forbidden host... "
request github.com 2> /dev/null && echo "Not forbidden!" && exit 1 || echo "OK"

LOCAL_LOG_PATH=/tmp/gbf-proxy-local.log
if [ -f $LOCAL_LOG_PATH ]; then
    rm $LOCAL_LOG_PATH
fi

printf "Spinning up local service... "
run local > $LOCAL_LOG_PATH &
LOCAL_PID=$!
pkill -0 -P $LOCAL_PID > /dev/null 2>&1 || (echo "Local service fails to run!" >&2 && exit 1)
while [ -z "$LOCAL_ADDRESS" ]; do
    LOCAL_ADDRESS=$(cat $LOCAL_LOG_PATH | awk '{ print $NF }')
    sleep 1
done
echo "Local service listening at $LOCAL_ADDRESS"
PROXY_ADDRESS="$LOCAL_ADDRESS"

printf "Testing local service... "
request game.granbluefantasy.jp | grep -q "グランブルーファンタジー" && echo "OK" || (echo "FAIL!" && exit 1)
