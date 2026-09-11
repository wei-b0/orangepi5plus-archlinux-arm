#!/usr/bin/env bash
set -euo pipefail

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
source "$repo_root/config/versions.env"
download_dir="$repo_root/downloads"
mkdir -p "$download_dir/git"

fetch_file() {
    local url=$1
    local destination=$2
    if [ ! -f "$destination" ]; then
        curl -fL --retry 3 --continue-at - --output "$destination" "$url"
    fi
}

verify_sha256() {
    local expected=$1
    local file=$2
    printf '%s  %s\n' "$expected" "$file" | sha256sum --check --status
}

fetch_git() {
    local name=$1
    local url=$2
    local commit=$3
    local destination="$download_dir/git/$name.git"
    if [ ! -d "$destination" ]; then
        git init --bare "$destination"
    fi
    if ! git -C "$destination" cat-file -e "$commit^{commit}" 2>/dev/null; then
        git -C "$destination" fetch --depth 1 "$url" "$commit"
    fi
    test "$(git -C "$destination" rev-parse "$commit^{commit}")" = "$commit"
}

rootfs_path="$download_dir/$ROOTFS_FILE"
rootfs_sig="$rootfs_path.sig"
keyring_asc="$download_dir/archlinuxarm-${ALARM_KEYRING_COMMIT}.gpg.asc"
keyring_bin="$download_dir/archlinuxarm-${ALARM_KEYRING_COMMIT}.gpg"

fetch_file "$ROOTFS_URL" "$rootfs_path"
fetch_file "$ROOTFS_URL.sig" "$rootfs_sig"
fetch_file "https://raw.githubusercontent.com/archlinuxarm/archlinuxarm-keyring/$ALARM_KEYRING_COMMIT/archlinuxarm.gpg" "$keyring_asc"
verify_sha256 "$ROOTFS_SHA256" "$rootfs_path"
verify_sha256 "$ROOTFS_SIG_SHA256" "$rootfs_sig"
verify_sha256 "$ALARM_KEYRING_SHA256" "$keyring_asc"
test "$(md5sum "$rootfs_path" | cut -d' ' -f1)" = "$ROOTFS_MD5"
gpg --batch --yes --dearmor --output "$keyring_bin.tmp" "$keyring_asc"
mv "$keyring_bin.tmp" "$keyring_bin"
gpgv --keyring "$keyring_bin" "$rootfs_sig" "$rootfs_path"
gpgv --keyring "$keyring_bin" --status-fd 1 "$rootfs_sig" "$rootfs_path" | grep -q "VALIDSIG $ALARM_SIGNER_FINGERPRINT"

linux_tar="$download_dir/linux-$LINUX_VERSION.tar.xz"
fetch_file "https://cdn.kernel.org/pub/linux/kernel/v6.x/linux-$LINUX_VERSION.tar.xz" "$linux_tar"
verify_sha256 "$LINUX_SHA256" "$linux_tar"

fetch_git u-boot https://source.denx.de/u-boot/u-boot.git "$UBOOT_COMMIT"
fetch_git trusted-firmware-a https://git.trustedfirmware.org/TF-A/trusted-firmware-a.git "$ATF_COMMIT"
fetch_git rkbin https://github.com/rockchip-linux/rkbin.git "$RKBIN_COMMIT"

git -C "$download_dir/git/rkbin.git" cat-file -e "$RKBIN_COMMIT:$RKBIN_DDR"
if [ "${SKIP_PACKAGE_LOCK:-0}" != 1 ]; then
    test -s "$repo_root/config/packages.lock"
    (cd "$repo_root" && sha256sum --check --strict config/packages.lock)
fi
printf '%s\n' "Verified all pinned source inputs."
