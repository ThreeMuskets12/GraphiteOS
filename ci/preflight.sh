#!/bin/bash
# Runs on the GitHub runner before any server is created. For every patched project it checks
# out the revision pinned by the GrapheneOS TAG manifest and applies our patches (3-way), so a
# conflict stops the release before anything is billed.
#
# Usage: ci/preflight.sh TAG PREV_TAG
# Output in work/:
#   patches/<project>/*.patch   patches rebased onto TAG (what the build VM applies)
#   review/applied-*.diff        our changes as applied to TAG
#   review/upstream-*.diff       upstream changes PREV_TAG -> TAG in the files we patch

set -o errexit -o nounset -o pipefail

readonly tag=$1 prev_tag=${2:-}
readonly root=$PWD work=$PWD/work
rm -rf "$work" && mkdir -p "$work/patches" "$work/review" "$work/src"

manifest() { # TAG -> manifest xml
    curl -fsS "https://raw.githubusercontent.com/GrapheneOS/platform_manifest/refs/tags/$1/default.xml"
}
project_info() { # MANIFEST_FILE PATH -> "URL REVISION"
    python3 - "$1" "$2" <<'EOF'
import sys, xml.etree.ElementTree as ET
root = ET.parse(sys.argv[1]).getroot()
default = root.find("default").attrib
remotes = {r.get("name"): r.get("fetch").rstrip("/") for r in root.iter("remote")}
for p in root.iter("project"):
    if p.get("path", p.get("name")) == sys.argv[2]:
        remote = p.get("remote", default.get("remote"))
        print(f'{remotes[remote]}/{p.get("name")} {p.get("revision", default.get("revision"))}')
        break
else:
    sys.exit(f"{sys.argv[2]} not found in manifest")
EOF
}

manifest "$tag" > "$work/manifest.xml"
[[ -n $prev_tag ]] && manifest "$prev_tag" > "$work/prev-manifest.xml"

git config --global user.name GraphiteOS
git config --global user.email graphiteos@localhost

(cd patches && find . -name '*.patch' -exec dirname {} \; | sort -u) | while read -r project; do
    project=${project#./}
    slug=${project//\//_}
    read -r url rev < <(project_info "$work/manifest.xml" "$project")
    echo "== $project @ $rev"
    git clone -q --filter=blob:none --no-checkout "$url" "$work/src/$slug"
    cd "$work/src/$slug"
    git cat-file -e "$rev^{commit}" 2>/dev/null || git fetch -q origin "$rev"
    git checkout -q "$rev"
    if ! git am -3 -q "$root/patches/$project"/*.patch; then
        git am --show-current-patch=diff | head -n 50 || true
        git diff --name-only --diff-filter=U
        echo "ERROR: GraphiteOS patches no longer apply to $project at $tag" >&2
        exit 1
    fi
    git format-patch -q "$rev..HEAD" -o "$work/patches/$project"
    git diff "$rev" HEAD > "$work/review/applied-$slug.diff"
    if [[ -n $prev_tag ]]; then
        read -r _ prev_rev < <(project_info "$work/prev-manifest.xml" "$project")
        git fetch -q origin "$prev_rev"
        git diff "$prev_rev" "$rev" -- $(git diff --name-only "$rev" HEAD) \
            > "$work/review/upstream-$slug.diff"
    fi
    cd "$root"
done
echo "patches apply cleanly to $tag"
