#!/bin/bash
# Minimal Hetzner Cloud helper. Needs HCLOUD_TOKEN, curl and jq.
#
#   ci/hetzner.sh create NAME SERVER_TYPE HOURS PUBKEY_FILE   -> prints "SERVER_ID IP"
#   ci/hetzner.sh delete NAME                                  (server and its SSH key)
#   ci/hetzner.sh extend NAME HOURS                            (expire HOURS from now)
#   ci/hetzner.sh delete-expired                               (everything past its expiry label)
#
# Every resource gets the labels graphiteos=1 and expires=<unix time>, so the scheduled
# cleanup workflow can delete anything a crashed workflow left behind.

set -o errexit -o nounset -o pipefail

readonly API=https://api.hetzner.cloud/v1
readonly LOCATIONS=(hel1 fsn1 nbg1 ash hil)
readonly IMAGE=ubuntu-24.04

api() { # METHOD PATH [JSON]
    curl -fsS -X "$1" -H "Authorization: Bearer $HCLOUD_TOKEN" -H "Content-Type: application/json" \
        ${3:+--data "$3"} "$API$2"
}

delete_by_name() { # NAME
    local id
    id=$(api GET "/servers?name=$1" | jq -r '.servers[0].id // empty')
    [[ -n $id ]] && api DELETE "/servers/$id" >/dev/null && echo "deleted server $1"
    id=$(api GET "/ssh_keys?name=$1" | jq -r '.ssh_keys[0].id // empty')
    [[ -n $id ]] && api DELETE "/ssh_keys/$id" >/dev/null && echo "deleted ssh key $1"
    return 0
}

case "$1" in
create)
    name=$2 type=$3 hours=$4 pubkey_file=$5
    labels=$(jq -n --arg e "$(( $(date +%s) + hours * 3600 ))" '{graphiteos: "1", expires: $e}')
    key_id=$(api POST /ssh_keys "$(jq -n --arg n "$name" --rawfile k "$pubkey_file" --argjson l "$labels" \
        '{name: $n, public_key: ($k | rtrimstr("\n")), labels: $l}')" | jq -r .ssh_key.id)
    for location in "${LOCATIONS[@]}"; do
        body=$(jq -n --arg n "$name" --arg t "$type" --arg i "$IMAGE" --arg loc "$location" \
            --argjson k "$key_id" --argjson l "$labels" \
            '{name: $n, server_type: $t, image: $i, location: $loc, ssh_keys: [$k], labels: $l}')
        out=$(curl -sS -X POST -H "Authorization: Bearer $HCLOUD_TOKEN" \
            -H "Content-Type: application/json" --data "$body" "$API/servers")
        if [[ $(jq -r '.server.id // empty' <<<"$out") ]]; then
            id=$(jq -r .server.id <<<"$out")
            ip=$(jq -r .server.public_net.ipv4.ip <<<"$out")
            echo "created $type in $location" >&2
            echo "$id $ip"
            exit 0
        fi
        echo "$type not created in $location: $(jq -r '.error.message // .' <<<"$out")" >&2
    done
    api DELETE "/ssh_keys/$key_id" >/dev/null
    echo "could not create $type in any location" >&2
    exit 1
    ;;
delete)
    delete_by_name "$2"
    ;;
extend)
    expires=$(( $(date +%s) + $3 * 3600 ))
    labels=$(jq -n --arg e "$expires" '{labels: {graphiteos: "1", expires: $e}}')
    for kind in servers ssh_keys; do
        id=$(api GET "/$kind?name=$2" | jq -r ".${kind}[0].id // empty")
        [[ -n $id ]] && api PUT "/$kind/$id" "$labels" >/dev/null
    done
    echo "$2 now expires at $(date -u -d "@$expires" 2>/dev/null || date -u -r "$expires")"
    ;;
delete-expired)
    now=$(date +%s)
    for kind in servers ssh_keys; do
        api GET "/$kind?label_selector=graphiteos&per_page=50" |
            jq -r --argjson now "$now" ".${kind}[] | select((.labels.expires | tonumber) < \$now) | .name" |
            while read -r name; do delete_by_name "$name"; done
    done
    ;;
*)
    echo "usage: $0 create|delete|delete-expired ..." >&2
    exit 2
    ;;
esac
