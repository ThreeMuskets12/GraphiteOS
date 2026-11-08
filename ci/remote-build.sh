#!/bin/bash
# Drives ci/vm-build.sh on a build server. The build runs detached on the server, so it survives
# dropped SSH connections and can span several GitHub jobs (each is limited to 6 hours).
#
#   ci/remote-build.sh start IP KEY      upload inputs and start the build
#                                        env: TAG BUILD_NUMBER PREV_TIMESTAMP
#                                             SIGNING_KEYS_TGZ_B64 SIGNING_KEYS_PASSPHRASE
#   ci/remote-build.sh wait IP KEY UNTIL stream the log until the build ends or UNTIL (unix time)
#                                        exit 0 = built, 100 = still running, other = failed
#   ci/remote-build.sh fetch IP KEY DIR  copy the release files to DIR

set -o errexit -o nounset -o pipefail

readonly mode=$1 ip=$2 key=$3
vm() { ssh -i "$key" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR \
    -o ConnectTimeout=15 -o ServerAliveInterval=30 "root@$ip" "$@"; }

case $mode in
start)
    for _ in $(seq 60); do vm true 2>/dev/null && break; sleep 5; done
    vm true || { echo "server not reachable over SSH" >&2; exit 1; }
    vm 'mkdir -p /build/graphiteos /dev/shm/graphite && chmod 700 /dev/shm/graphite'
    tar -czf - --exclude=.git --exclude=work/venv --exclude=work/src . | vm 'tar -xzf - -C /build/graphiteos'
    printf '%s' "$SIGNING_KEYS_TGZ_B64" | vm 'cat > /dev/shm/graphite/keys.b64'
    printf '%s' "$SIGNING_KEYS_PASSPHRASE" | vm 'cat > /dev/shm/graphite/passphrase'
    printf 'TAG=%q\nBUILD_NUMBER=%q\nPREV_TIMESTAMP=%q\n' "$TAG" "$BUILD_NUMBER" "$PREV_TIMESTAMP" |
        vm 'cat > /dev/shm/graphite/env'
    vm 'setsid nohup bash -c "bash /build/graphiteos/ci/vm-build.sh; echo \$? > /build/exit-code" \
        > /build/build.log 2>&1 < /dev/null &'
    ;;
wait)
    until_time=$4 offset=0 failures=0 ticks=0
    while true; do
        if chunk=$(vm "tail -c +$((offset + 1)) /build/build.log"); then
            failures=0
            printf '%s' "$chunk"
            offset=$((offset + $(printf '%s' "$chunk" | wc -c)))
        elif (( ++failures > 20 )); then
            echo "lost contact with the server" >&2
            exit 1
        fi
        if code=$(vm 'cat /build/exit-code 2>/dev/null') && [[ -n $code ]]; then
            vm "tail -c +$((offset + 1)) /build/build.log" || true
            exit "$code"
        fi
        (( $(date +%s) >= until_time )) && { echo "build still running, continuing in the next job"; exit 100; }
        # show build progress every 5 minutes
        (( ++ticks % 10 == 0 )) && vm 'tail -c 2000 /build/m.log 2>/dev/null | tr "\r" "\n" | tail -n 1' || true
        sleep 30
    done
    ;;
fetch)
    mkdir -p "$4"
    scp -i "$key" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR \
        "root@$ip:/build/upload/*" "$4/"
    ;;
*)
    echo "usage: $0 start|wait|fetch IP KEY ..." >&2
    exit 2
    ;;
esac
