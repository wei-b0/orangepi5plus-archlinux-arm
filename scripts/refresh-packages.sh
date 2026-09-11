#!/usr/bin/env bash
set -euo pipefail

repo_root=/repo
source "$repo_root/config/versions.env"
work_root=${WORK_ROOT:-/work/package-refresh}
stage_dir="$work_root/rootfs"
cache_dir="$stage_dir/package-cache"
next_packages="$repo_root/downloads/packages.next"
next_databases="$repo_root/downloads/repo-db.next"

cleanup_runtime_mounts() {
    local path
    for path in dev proc; do
        if mountpoint -q "$stage_dir/$path"; then
            umount -R "$stage_dir/$path" || umount -l -R "$stage_dir/$path"
        fi
    done
}

trap cleanup_runtime_mounts EXIT

SKIP_PACKAGE_LOCK=1 "$repo_root/scripts/fetch.sh"
rm -rf "$stage_dir" "$cache_dir" "$next_packages" "$next_databases"
mkdir -p "$stage_dir" "$cache_dir" "$next_packages" "$next_databases"
bsdtar -xpf "$repo_root/downloads/$ROOTFS_FILE" -C "$stage_dir"
rm -f "$stage_dir/etc/resolv.conf"
install -m 0644 /etc/resolv.conf "$stage_dir/etc/resolv.conf"
sed -i '/^\[options\]/a DisableSandbox' "$stage_dir/etc/pacman.conf"
rm -f "$stage_dir/etc/mtab"
printf '%s\n' 'none / ext4 rw 0 0' 'proc /proc proc rw 0 0' > "$stage_dir/etc/mtab"
mount -t proc proc "$stage_dir/proc"
mount --rbind /dev "$stage_dir/dev"
mount --make-rslave "$stage_dir/dev"
chroot "$stage_dir" chown alpm:alpm /package-cache
chroot "$stage_dir" pacman-key --init
chroot "$stage_dir" pacman-key --populate archlinux archlinuxarm
mapfile -t requested_packages < <(sed '/^[[:space:]]*$/d' "$repo_root/config/packages.txt")
chroot "$stage_dir" pacman -Sy --noconfirm
mapfile -t package_urls < <(chroot "$stage_dir" pacman -Sup --print-format '%l' --ignore linux-aarch64 "${requested_packages[@]}")
chroot "$stage_dir" pacman -Suw --noconfirm --needed --ignore linux-aarch64 --cachedir /package-cache "${requested_packages[@]}"
find "$cache_dir" -maxdepth 1 -type f -name '*.pkg.tar.*' ! -name '*.sig' -exec install -m 0644 {} "$next_packages/" \;
for package_url in "${package_urls[@]}"; do
    package_file=${package_url##*/}
    package_file=${package_file%%\?*}
    if [ -f "$next_packages/$package_file" ]; then
        curl -fsSL --retry 3 --output "$next_packages/$package_file.sig" "$package_url.sig"
    fi
done
find "$stage_dir/var/lib/pacman/sync" -maxdepth 1 -type f -exec install -m 0644 {} "$next_databases/" \;
signature_count=0
: > "$repo_root/config/package-signers.txt.tmp"
for signature in "$next_packages"/*.sig; do
    package=${signature%.sig}
    gpg --homedir "$stage_dir/etc/pacman.d/gnupg" --batch --status-fd 1 --verify "$signature" "$package" 2>/dev/null \
        | awk '$2 == "VALIDSIG" {print $3}' >> "$repo_root/config/package-signers.txt.tmp"
    signature_count=$((signature_count + 1))
done
test "$signature_count" -gt 0
sort -u "$repo_root/config/package-signers.txt.tmp" -o "$repo_root/config/package-signers.txt.tmp"
chroot "$stage_dir" gpgconf --kill all || true
cleanup_runtime_mounts
rm -rf "$repo_root/downloads/packages" "$repo_root/downloads/repo-db"
mv "$next_packages" "$repo_root/downloads/packages"
mv "$next_databases" "$repo_root/downloads/repo-db"
(
    cd "$repo_root"
    find downloads/packages downloads/repo-db -type f -print | LC_ALL=C sort | xargs sha256sum > config/packages.lock.tmp
)
mv "$repo_root/config/packages.lock.tmp" "$repo_root/config/packages.lock"
mv "$repo_root/config/package-signers.txt.tmp" "$repo_root/config/package-signers.txt"
printf 'packages=%s\nsigners=%s\n' "$(find "$repo_root/downloads/packages" -type f -name '*.pkg.tar.*' ! -name '*.sig' | wc -l)" "$(wc -l < "$repo_root/config/package-signers.txt")"
