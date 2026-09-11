#!/usr/bin/env bash
set -euo pipefail

repo_root=/repo
source "$repo_root/config/versions.env"
work_root=${WORK_ROOT:-/work/nvme-kernel}
source_dir="$work_root/sources"
build_dir="$work_root/build"
log_dir="$repo_root/dist/logs/nvme-kernel"
image="$repo_root/dist/$IMAGE_NAME"
tmp_image="$repo_root/dist/.$IMAGE_NAME.nvme.tmp"
mkdir -p "$log_dir"

KERNEL_ONLY=1 WORK_ROOT="$work_root" RUN_LABEL=nvme-kernel OUTPUT_NAME="$IMAGE_NAME" \
    source "$repo_root/scripts/build-in-container.sh"

prepare_sources
build_linux 2>&1 | tee "$log_dir/linux.log"
create_kernel_package 2>&1 | tee "$log_dir/kernel-package.log"

test -s "$build_dir/linux-orangepi5plus-$KERNEL_PACKAGE_VERSION-aarch64.pkg.tar.zst"
test -s "$image"
rm -f "$tmp_image"
cp -p "$image" "$tmp_image"

root_start_bytes=$((ROOT_START_SECTOR * 512))
mount_dir="$work_root/mnt"
mkdir -p "$mount_dir"
mount -o loop,offset="$root_start_bytes" "$tmp_image" "$mount_dir"
cleanup_mount() {
    if mountpoint -q "$mount_dir"; then
        umount "$mount_dir" || umount -l "$mount_dir"
    fi
}
trap cleanup_mount EXIT

mount -t proc proc "$mount_dir/proc"
mount --rbind /sys "$mount_dir/sys"
mount --make-rslave "$mount_dir/sys"
mount --rbind /dev "$mount_dir/dev"
mount --make-rslave "$mount_dir/dev"
rm -f "$mount_dir/etc/mtab"
printf '%s\n' 'none / ext4 rw 0 0' 'proc /proc proc rw 0 0' > "$mount_dir/etc/mtab"
install -m 0644 "$build_dir/linux-orangepi5plus-$KERNEL_PACKAGE_VERSION-aarch64.pkg.tar.zst" "$mount_dir/tmp/kernel.pkg.tar.zst"
chroot "$mount_dir" pacman -U --noconfirm /tmp/kernel.pkg.tar.zst
rm -f "$mount_dir/tmp/kernel.pkg.tar.zst"
chroot "$mount_dir" depmod "${LINUX_VERSION}-orangepi5plus"
rm -f "$mount_dir/etc/mtab"
ln -s /proc/self/mounts "$mount_dir/etc/mtab"
chroot "$mount_dir" gpgconf --kill all || true
umount -R "$mount_dir/dev" || umount -l -R "$mount_dir/dev"
umount -R "$mount_dir/sys" || umount -l -R "$mount_dir/sys"
umount "$mount_dir/proc" || umount -l "$mount_dir/proc"
cleanup_mount
trap - EXIT

mv "$tmp_image" "$image"
zstd -q -T1 -"$IMAGE_ZSTD_LEVEL" -f "$image" -o "$work_root/$IMAGE_NAME.zst.tmp"
mv "$work_root/$IMAGE_NAME.zst.tmp" "$image.zst"
(cd "$repo_root/dist" && sha256sum "$IMAGE_NAME" > "$IMAGE_NAME.sha256")
(cd "$repo_root/dist" && sha256sum "$IMAGE_NAME.zst" > "$IMAGE_NAME.zst.sha256")
"$repo_root/scripts/inspect.sh" "$image" | tee "$repo_root/dist/inspection.txt"
