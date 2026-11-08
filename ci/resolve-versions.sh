#!/bin/bash
# Works out what to build and prints GitHub step outputs:
#   tag, build_number, prev_tag, prev_timestamp
# Env: TAG_IN (blank = current caiman stable), BUILD_NUMBER_IN (blank = tag), GH_REPO, GH_TOKEN

set -o errexit -o nounset -o pipefail

tag=${TAG_IN:-$(curl -fsS https://releases.grapheneos.org/caiman-stable | cut -d' ' -f1)}
build_number=${BUILD_NUMBER_IN:-$tag}
[[ $tag =~ ^[0-9]{10}$ && $build_number =~ ^[0-9]{10}$ ]] || { echo "bad tag/build number" >&2; exit 1; }

if gh release view "$build_number" >/dev/null 2>&1; then
    echo "release $build_number already exists (a rebuild needs a new build number, tag + 50..99)" >&2
    exit 1
fi

prev_tag="" prev_timestamp=0
prev=$(gh release list --exclude-drafts --limit 1 --json tagName --jq '.[0].tagName // ""')
if [[ -n $prev ]]; then
    prev_tag=$(gh release view "$prev" --json body --jq .body | sed -n 's/^Upstream: GrapheneOS \([0-9]*\).*/\1/p')
    prev_timestamp=$(gh release download "$prev" -p caiman-stable -O - | cut -d' ' -f2)
    # Never go back to an older GrapheneOS release: its firmware could be older than the phone's.
    (( tag >= prev_tag )) || { echo "tag $tag is older than the last release's $prev_tag" >&2; exit 1; }
fi

echo "tag=$tag"
echo "build_number=$build_number"
echo "prev_tag=$prev_tag"
echo "prev_timestamp=$prev_timestamp"
