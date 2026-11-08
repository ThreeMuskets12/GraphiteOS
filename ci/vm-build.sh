#!/bin/bash
# Runs on the build VM as root (started by ci/remote-build.sh).
# Installs dependencies, syncs and verifies the GrapheneOS tag, applies the GraphiteOS patches,
# builds and signs a release, checks it, and uploads it to the draft GitHub release.
#
# Inputs: /build/graphiteos (this repo, with preflight output in work/), and in /dev/shm/graphite:
#   env (TAG, BUILD_NUMBER, PREV_TIMESTAMP, REPO, GH_TOKEN), keys.b64, passphrase

set -o errexit -o nounset -o pipefail

readonly DEVICE=caiman
readonly GRAPHITE=/build/graphiteos
readonly SRC=/build/src
readonly SECRETS=/dev/shm/graphite

log() { echo "=== $(date -u +%H:%M:%S) $*"; }
die() { echo "ERROR: $*" >&2; exit 1; }
# run a noisy command with its output in a file; show the end of it on failure
quiet() { local name=$1; shift; "$@" > "/build/$name.log" 2>&1 || { tail -n 150 "/build/$name.log"; die "$name failed"; }; }

source "$SECRETS/env"

if [[ ${1:-} != --as-build ]]; then
    log "installing dependencies"
    export DEBIAN_FRONTEND=noninteractive
    quiet apt apt-get update
    quiet apt apt-get install -y repo git gnupg openssh-client python3 diffutils fontconfig \
        fonts-dejavu-core openssl rsync unzip zip curl jq gh xz-utils
    node_dist=https://nodejs.org/dist/latest-v24.x
    node_tar=$(curl -fsS "$node_dist/SHASUMS256.txt" | grep -o 'node-v[0-9.]*-linux-x64\.tar\.xz' | head -n 1)
    curl -fsS "$node_dist/$node_tar" -o "/tmp/$node_tar"
    (cd /tmp && curl -fsS "$node_dist/SHASUMS256.txt" | grep " $node_tar\$" | sha256sum -c --quiet -)
    tar -xJf "/tmp/$node_tar" -C /usr/local --strip-components=1
    quiet npm npm install -g yarn

    id build &>/dev/null || useradd -m -s /bin/bash build
    mkdir -p "$SRC"
    chown -R build: /build
    chown -R build: "$SECRETS"
    runuser -u build -- bash "$0" --as-build

    log "uploading release assets"
    out="$SRC/releases/$BUILD_NUMBER/release-$DEVICE-$BUILD_NUMBER"
    cd "$out"
    install_zip="$DEVICE-install-$BUILD_NUMBER.zip"
    sha256sum "$DEVICE-ota_update-$BUILD_NUMBER.zip" "$install_zip" > SHA256SUMS
    # GitHub release files are limited to 2 GiB; the install zip is only needed for the first flash
    split -b 1900M -d -a 1 "$install_zip" "$install_zip.part"
    GH_TOKEN=$GH_TOKEN gh release upload "$BUILD_NUMBER" --repo "$REPO" --clobber \
        "$DEVICE-ota_update-$BUILD_NUMBER.zip" "$DEVICE"-{stable,beta,alpha,testing} \
        "$install_zip".part* SHA256SUMS
    log "done"
    exit 0
fi

# ---- everything below runs as the unprivileged build user ----------------------------------------
cd "$SRC"
git config --global user.name GraphiteOS
git config --global user.email graphiteos@localhost
git config --global color.ui false

log "syncing GrapheneOS $TAG"
quiet repo-init repo init -u https://github.com/GrapheneOS/platform_manifest.git -b "refs/tags/$TAG"
curl -fsS https://grapheneos.org/allowed_signers > ~/grapheneos_allowed_signers
git -C .repo/manifests config gpg.ssh.allowedSignersFile ~/grapheneos_allowed_signers
git -C .repo/manifests verify-tag "$(git -C .repo/manifests describe)" || die "manifest tag signature check failed"
# Standard sync (not --depth=1: after a failed fetch repo silently falls back to full history,
# which overflows the disk). Google rate limits parallel fetches (RESOURCE_EXHAUSTED), so stay gentle and
# back off; each retry only fetches what is still missing.
for attempt in 1 2 3 4 5 6; do
    repo sync -c -j4 --no-tags > /build/repo-sync.log 2>&1 && break
    [[ $attempt == 6 ]] && { tail -n 150 /build/repo-sync.log; die "repo sync failed"; }
    log "repo sync failed, retrying"
    sleep $((attempt * 120))
done

log "applying GraphiteOS patches"
(cd "$GRAPHITE/work/patches" && find . -name '*.patch' -exec dirname {} \; | sort -u) | while read -r project; do
    project=${project#./}
    git -C "$project" am "$GRAPHITE/work/patches/$project"/*.patch || die "patch failed in $project"
done

log "applying GraphiteOS file replacements"
(cd "$GRAPHITE/overlay" && find . -type f) | while read -r file; do
    [[ -f $file ]] || die "$file no longer exists upstream, so its replacement would be ignored"
    cp "$GRAPHITE/overlay/$file" "$file"
done

log "setting up signing keys"
mkdir -p "keys/$DEVICE"
base64 -d "$SECRETS/keys.b64" | tar -xz -C "keys/$DEVICE"
cp "$GRAPHITE/certs/$DEVICE"/* "keys/$DEVICE/"
signing_keys=$(source script/common.sh && echo "${signing_keys[@]}")
for key in $signing_keys; do
    [[ -f keys/$DEVICE/$key.pk8 && -f keys/$DEVICE/$key.x509.pem ]] ||
        die "missing signing key '$key': GrapheneOS added a key, generate it before building"
done

log "building"
export OFFICIAL_BUILD=true BUILD_NUMBER BUILD_DATETIME="$(date +%s)"
export BUILD_HOSTNAME=graphiteos BUILD_USERNAME=graphiteos
set +o nounset # envsetup.sh is not nounset-safe
source build/envsetup.sh
quiet yarn yarn --cwd vendor/adevtool/ install
quiet adevtool adevtool generate-all -d "$DEVICE"
lunch "$DEVICE-cur-user" > /build/lunch.log 2>&1 || { cat /build/lunch.log; die "lunch failed"; }
quiet m m vendorbootimage vendorkernelbootimage target-files-package
quiet otatools m otatools-package
set -o nounset
cmp "$OUT/product/media/bootanimation.zip" "$GRAPHITE/overlay/branding/bootanimation/1280.zip" ||
    die "the build didn't pick up the GraphiteOS boot animation"

log "signing"
quiet finalize script/finalize.sh
password=$(cat "$SECRETS/passphrase")
export password
quiet generate-release script/generate-release.sh "$DEVICE" "$BUILD_NUMBER"
unset password

log "checking the release"
out="releases/$BUILD_NUMBER/release-$DEVICE-$BUILD_NUMBER"
ota="$out/$DEVICE-ota_update-$BUILD_NUMBER.zip"
PATH="$PWD/$out/bin:$PATH" PYTHONPATH=build/make/tools/releasetools \
    python3 build/make/tools/releasetools/check_ota_package_signature.py \
    "keys/$DEVICE/releasekey.x509.pem" "$ota" || die "OTA signature check failed"
# The Updater only accepts an update whose zip metadata matches the channel metadata and whose
# timestamp is newer than the installed build.
python3 - "$ota" "$out/$DEVICE-stable" "$DEVICE" "$BUILD_NUMBER" "$PREV_TIMESTAMP" <<'EOF'
import sys, zipfile
ota, channel, device, build_number, prev_timestamp = sys.argv[1:]
with zipfile.ZipFile(ota) as z:
    meta = dict(l.split("=", 1) for l in z.read("META-INF/com/android/metadata").decode().splitlines())
incremental, timestamp, meta_device, name = open(channel).read().split()
checks = {
    "channel incremental == build number": incremental == build_number,
    "zip post-build incremental == build number": meta["post-build"].split("/")[4].split(":")[0] == build_number,
    "zip post-timestamp == channel timestamp": meta["post-timestamp"] == timestamp,
    "device": meta_device == device and meta["pre-device"] == device,
    "A/B update": meta.get("ota-type") == "AB",
    "newer than previous release": int(timestamp) > int(prev_timestamp),
}
for check, ok in checks.items():
    print(("ok   " if ok else "FAIL ") + check)
sys.exit(0 if all(checks.values()) else 1)
EOF
log "build finished"
