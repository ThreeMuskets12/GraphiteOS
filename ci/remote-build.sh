#!/bin/bash
# Runs ci/vm-build.sh on a fresh build VM and streams its log until it finishes.
# The build runs detached on the VM, so a dropped SSH connection doesn't kill it.
#
# Usage: ci/remote-build.sh IP SSH_KEY
# Env: TAG BUILD_NUMBER PREV_TIMESTAMP REPO GH_TOKEN SIGNING_KEYS_TGZ_B64 SIGNING_KEYS_PASSPHRASE

set -o errexit -o nounset -o pipefail

readonly ip=$1 key=$2
vm() { ssh -i "$key" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR \
    -o ConnectTimeout=15 -o ServerAliveInterval=30 "root@$ip" "$@"; }

for _ in $(seq 60); do vm true 2>/dev/null && break; sleep 5; done
vm true || { echo "VM not reachable over SSH" >&2; exit 1; }

vm 'mkdir -p /build/graphiteos /dev/shm/graphite && chmod 700 /dev/shm/graphite'
tar -czf - --exclude=.git . | vm 'tar -xzf - -C /build/graphiteos'
printf '%s' "$SIGNING_KEYS_TGZ_B64" | vm 'cat > /dev/shm/graphite/keys.b64'
printf '%s' "$SIGNING_KEYS_PASSPHRASE" | vm 'cat > /dev/shm/graphite/passphrase'
printf 'TAG=%q\nBUILD_NUMBER=%q\nPREV_TIMESTAMP=%q\nREPO=%q\nGH_TOKEN=%q\n' \
    "$TAG" "$BUILD_NUMBER" "$PREV_TIMESTAMP" "$REPO" "$GH_TOKEN" | vm 'cat > /dev/shm/graphite/env'

vm 'setsid nohup bash -c "bash /build/graphiteos/ci/vm-build.sh; echo \$? > /build/exit-code" \
    > /build/build.log 2>&1 < /dev/null &'

offset=0 failures=0 ticks=0
while true; do
    sleep 30
    if ! chunk=$(vm "tail -c +$((offset + 1)) /build/build.log"); then
        (( ++failures > 20 )) && { echo "lost contact with the VM" >&2; exit 1; }
        continue
    fi
    failures=0
    printf '%s' "$chunk"
    offset=$((offset + $(printf '%s' "$chunk" | wc -c)))
    # show build progress every 5 minutes
    (( ++ticks % 10 == 0 )) && vm 'tail -n 1 /build/m.log 2>/dev/null | tr "\r" "\n" | tail -n 1' || true
    if code=$(vm 'cat /build/exit-code 2>/dev/null') && [[ -n $code ]]; then
        vm "tail -c +$((offset + 1)) /build/build.log" || true
        exit "$code"
    fi
done
