#!/usr/bin/env bash
set -euo pipefail

repo_root=/repo
source "$repo_root/config/versions.env"
work_root=${WORK_ROOT:-/work/default}
output_name=${OUTPUT_NAME:-$IMAGE_NAME}
jobs=${JOBS:-$(nproc)}
source_dir="$work_root/sources"
build_dir="$work_root/build"
stage_dir="$work_root/rootfs"
package_dir="$work_root/kernel-package"
run_label=${RUN_LABEL:-latest}
log_dir="$repo_root/dist/logs/$run_label"
mkdir -p "$source_dir" "$build_dir" "$log_dir" "$repo_root/dist"

export SOURCE_DATE_EPOCH KBUILD_BUILD_TIMESTAMP="@$SOURCE_DATE_EPOCH"
export KBUILD_BUILD_USER=builder KBUILD_BUILD_HOST=orangepi5plus
export TZ=UTC LANG=C.UTF-8 LC_ALL=C.UTF-8

cleanup_runtime_mounts() {
    local path
    if mountpoint -q "$stage_dir/tmp/orangepi-packages"; then
        umount "$stage_dir/tmp/orangepi-packages" || umount -l "$stage_dir/tmp/orangepi-packages"
    fi
    for path in dev sys proc; do
        if mountpoint -q "$stage_dir/$path"; then
            umount -R "$stage_dir/$path" || umount -l -R "$stage_dir/$path"
        fi
    done
}

trap cleanup_runtime_mounts EXIT

"$repo_root/scripts/fetch.sh" 2>&1 | tee "$log_dir/fetch.log"

prepare_sources() {
    if [ ! -f "$source_dir/.prepared-$LINUX_VERSION-$UBOOT_COMMIT-$ATF_COMMIT-$RKBIN_COMMIT" ]; then
        rm -rf "$source_dir/linux" "$source_dir/u-boot" "$source_dir/trusted-firmware-a" "$source_dir/rkbin"
        mkdir -p "$source_dir/linux" "$source_dir/u-boot" "$source_dir/trusted-firmware-a" "$source_dir/rkbin"
        tar -xJf "$repo_root/downloads/linux-$LINUX_VERSION.tar.xz" --strip-components=1 -C "$source_dir/linux"
        git --git-dir="$repo_root/downloads/git/u-boot.git" archive "$UBOOT_COMMIT" | tar -xf - -C "$source_dir/u-boot"
        git --git-dir="$repo_root/downloads/git/trusted-firmware-a.git" archive "$ATF_COMMIT" | tar -xf - -C "$source_dir/trusted-firmware-a"
        git --git-dir="$repo_root/downloads/git/rkbin.git" archive "$RKBIN_COMMIT" | tar -xf - -C "$source_dir/rkbin"
        touch "$source_dir/.prepared-$LINUX_VERSION-$UBOOT_COMMIT-$ATF_COMMIT-$RKBIN_COMMIT"
    fi
}

build_atf() {
    if [ -f "$build_dir/.atf-$ATF_COMMIT" ] && [ -s "$build_dir/atf/rk3588/release/bl31/bl31.elf" ]; then
        printf '%s\n' 'Using cached Trusted Firmware-A build.'
        return
    fi
    make -C "$source_dir/trusted-firmware-a" BUILD_BASE="$build_dir/atf" realclean
    make -C "$source_dir/trusted-firmware-a" -j"$jobs" BUILD_BASE="$build_dir/atf" CROSS_COMPILE= PLAT=rk3588 bl31
    test -s "$build_dir/atf/rk3588/release/bl31/bl31.elf"
    touch "$build_dir/.atf-$ATF_COMMIT"
}

build_uboot() {
    local config_hash
    config_hash=$(sha256sum "$repo_root/config/u-boot.fragment" | cut -d' ' -f1)
    if [ -f "$build_dir/.u-boot-$UBOOT_COMMIT-$config_hash" ] && [ -s "$build_dir/u-boot/u-boot-rockchip.bin" ]; then
        printf '%s\n' 'Using cached U-Boot build.'
        return
    fi
    rm -rf "$build_dir/u-boot"
    mkdir -p "$build_dir/u-boot"
    make -C "$source_dir/u-boot" O="$build_dir/u-boot" orangepi-5-plus-rk3588_defconfig
    cat "$repo_root/config/u-boot.fragment" >> "$build_dir/u-boot/.config"
    make -C "$source_dir/u-boot" O="$build_dir/u-boot" olddefconfig
    make -C "$source_dir/u-boot" -j"$jobs" O="$build_dir/u-boot" \
        BL31="$build_dir/atf/rk3588/release/bl31/bl31.elf" \
        ROCKCHIP_TPL="$source_dir/rkbin/$RKBIN_DDR"
    test -s "$build_dir/u-boot/u-boot-rockchip.bin"
    touch "$build_dir/.u-boot-$UBOOT_COMMIT-$config_hash"
}

build_linux() {
    local config_hash
    config_hash=$(sha256sum "$repo_root/config/linux.fragment" | cut -d' ' -f1)
    if [ -f "$build_dir/.linux-$LINUX_VERSION-$config_hash" ] && [ -s "$build_dir/linux/arch/arm64/boot/Image" ]; then
        printf '%s\n' 'Using cached Linux build.'
        return
    fi
    rm -rf "$build_dir/linux"
    mkdir -p "$build_dir/linux"
    make -C "$source_dir/linux" O="$build_dir/linux" ARCH=arm64 defconfig
    "$source_dir/linux/scripts/kconfig/merge_config.sh" -m -O "$build_dir/linux" \
        "$build_dir/linux/.config" "$repo_root/config/linux.fragment"
    make -C "$source_dir/linux" O="$build_dir/linux" ARCH=arm64 olddefconfig
    make -C "$source_dir/linux" -j"$jobs" O="$build_dir/linux" ARCH=arm64 Image modules \
        rockchip/rk3588-orangepi-5-plus.dtb
    test -s "$build_dir/linux/arch/arm64/boot/Image"
    test -s "$build_dir/linux/arch/arm64/boot/dts/rockchip/rk3588-orangepi-5-plus.dtb"
    touch "$build_dir/.linux-$LINUX_VERSION-$config_hash"
}

create_kernel_package() {
    local config_hash package_marker package_path
    config_hash=$(sha256sum "$repo_root/config/linux.fragment" | cut -d' ' -f1)
    package_path="$build_dir/linux-orangepi5plus-$KERNEL_PACKAGE_VERSION-aarch64.pkg.tar.zst"
    package_marker="$build_dir/.kernel-package-$LINUX_VERSION-$KERNEL_PACKAGE_VERSION-$config_hash"
    if [ -f "$package_marker" ] && [ -s "$package_path" ]; then
        printf '%s\n' 'Using cached Linux package.'
        return
    fi
    rm -rf "$package_dir"
    mkdir -p "$package_dir/boot/dtbs/orangepi5plus/rockchip" "$package_dir/usr/lib/modules"
    install -m 0644 "$build_dir/linux/arch/arm64/boot/Image" "$package_dir/boot/Image-orangepi5plus"
    install -m 0644 "$build_dir/linux/.config" "$package_dir/boot/config-orangepi5plus"
    install -m 0644 "$build_dir/linux/arch/arm64/boot/dts/rockchip/rk3588-orangepi-5-plus.dtb" \
        "$package_dir/boot/dtbs/orangepi5plus/rockchip/rk3588-orangepi-5-plus.dtb"
    make -C "$source_dir/linux" O="$build_dir/linux" ARCH=arm64 \
        INSTALL_MOD_PATH="$package_dir/usr" INSTALL_MOD_STRIP=1 DEPMOD=true modules_install
    find "$package_dir" -name build -o -name source | xargs -r rm -f
    installed_size=$(du -sk --apparent-size "$package_dir" | cut -f1)
    printf '%s\n' \
        'pkgname = linux-orangepi5plus' \
        "pkgver = $KERNEL_PACKAGE_VERSION" \
        'pkgdesc = Mainline Linux for Orange Pi 5 Plus' \
        'url = https://kernel.org/' \
        "builddate = $SOURCE_DATE_EPOCH" \
        'packager = Orange Pi 5 Plus image builder' \
        "size = $((installed_size * 1024))" \
        'arch = aarch64' \
        'license = GPL2' \
        > "$package_dir/.PKGINFO"
    find "$package_dir" -print0 | xargs -0 touch --no-dereference --date="@$SOURCE_DATE_EPOCH"
    (
        cd "$package_dir"
        bsdtar -cf - --format=mtree --options='!all,use-set,type,uid,gid,mode,time,size,sha256,link' \
            .PKGINFO boot usr | gzip -n > "$build_dir/kernel-package.MTREE"
    )
    install -m 0644 "$build_dir/kernel-package.MTREE" "$package_dir/.MTREE"
    touch --date="@$SOURCE_DATE_EPOCH" "$package_dir/.MTREE"
    rm -f "$package_path"
    tar --sort=name --mtime="@$SOURCE_DATE_EPOCH" --owner=0 --group=0 --numeric-owner \
        --pax-option=delete=atime,delete=ctime -C "$package_dir" -cf - .MTREE .PKGINFO boot usr | zstd -3 -T1 -q -o "$package_path"
    touch "$package_marker"
}

create_rootfs() {
    rm -rf "$stage_dir"
    mkdir -p "$stage_dir"
    bsdtar -xpf "$repo_root/downloads/$ROOTFS_FILE" -C "$stage_dir"
    rm -f "$stage_dir/dev/null"
    mknod -m 0666 "$stage_dir/dev/null" c 1 3
    rm -rf "$stage_dir/boot"/*
    rm -f "$stage_dir/etc/mtab"
    printf '%s\n' 'none / ext4 rw 0 0' 'proc /proc proc rw 0 0' > "$stage_dir/etc/mtab"
    mount -t proc proc "$stage_dir/proc"
    mount --rbind /sys "$stage_dir/sys"
    mount --make-rslave "$stage_dir/sys"
    mount --rbind /dev "$stage_dir/dev"
    mount --make-rslave "$stage_dir/dev"
    chroot "$stage_dir" pacman-key --init
    chroot "$stage_dir" pacman-key --populate archlinux archlinuxarm
    mkdir -p "$stage_dir/tmp/orangepi-packages"
    mount --bind "$repo_root/downloads/packages" "$stage_dir/tmp/orangepi-packages"
    mount -o remount,bind,ro "$stage_dir/tmp/orangepi-packages"
    chroot "$stage_dir" sh -c "find /tmp/orangepi-packages -type f -name '*.pkg.tar.*' ! -name '*.sig' -print0 | LC_ALL=C sort -z | xargs -0 pacman -U --noconfirm --needed"
    umount "$stage_dir/tmp/orangepi-packages"
    rm -rf "$stage_dir/tmp/orangepi-packages"
    rm -f "$stage_dir/etc/mtab"
    printf '%s\n' 'none / ext4 rw 0 0' 'proc /proc proc rw 0 0' > "$stage_dir/etc/mtab"
    chroot "$stage_dir" pacman -Rdd --noconfirm linux-aarch64 || true
    cp "$build_dir/linux-orangepi5plus-$KERNEL_PACKAGE_VERSION-aarch64.pkg.tar.zst" "$stage_dir/tmp/kernel.pkg.tar.zst"
    chroot "$stage_dir" pacman -U --noconfirm /tmp/kernel.pkg.tar.zst
    rm -f "$stage_dir/tmp/kernel.pkg.tar.zst"
    chroot "$stage_dir" depmod "${LINUX_VERSION}-orangepi5plus"
    chroot "$stage_dir" gpgconf --kill all || true
    cleanup_runtime_mounts
    rm -f "$stage_dir/etc/mtab"
    ln -s /proc/self/mounts "$stage_dir/etc/mtab"
    find "$stage_dir/var/lib/pacman/local" -name desc -type f -exec sed -i "/%INSTALLDATE%/{n;s/.*/$SOURCE_DATE_EPOCH/;}" {} +
    rsync -aHAX "$repo_root/rootfs-overlay/" "$stage_dir/"
    chmod 0755 "$stage_dir/usr/local/sbin/op5-firstboot" "$stage_dir/usr/local/sbin/op5-grow-root"
    chmod 0440 "$stage_dir/etc/sudoers.d/10-alarm"
    chroot "$stage_dir" usermod -aG wheel alarm
    ln -sfn /run/systemd/resolve/stub-resolv.conf "$stage_dir/etc/resolv.conf"
    rm -f "$stage_dir/etc/machine-id"
    : > "$stage_dir/etc/machine-id"
    rm -f "$stage_dir/var/lib/dbus/machine-id" "$stage_dir/var/lib/systemd/random-seed"
    rm -f "$stage_dir/etc/nvme/hostid" "$stage_dir/etc/nvme/hostnqn" "$stage_dir/var/cache/ldconfig/aux-cache"
    rm -f "$stage_dir/etc/ssh/ssh_host_"*
    rm -rf "$stage_dir/etc/pacman.d/gnupg"
    install -d -m 0755 "$stage_dir/etc/pacman.d/gnupg"
    rm -rf "$stage_dir/var/cache/pacman/pkg"/*
    rm -rf "$stage_dir/etc/NetworkManager/system-connections"/* "$stage_dir/var/lib/NetworkManager"/* "$stage_dir/var/lib/iwd"/*
    find "$stage_dir/var/log" -mindepth 1 -maxdepth 1 ! -name journal -exec rm -rf {} +
    mkdir -p "$stage_dir/var/log/journal" "$stage_dir/usr/share/orangepi5plus"
    chmod 2755 "$stage_dir/var/log/journal"
    install -m 0644 "$repo_root/config/packages.txt" "$stage_dir/usr/share/orangepi5plus/packages.txt"
    install -m 0644 "$repo_root/config/packages.lock" "$stage_dir/usr/share/orangepi5plus/packages.lock"
    install -m 0644 "$repo_root/config/package-signers.txt" "$stage_dir/usr/share/orangepi5plus/package-signers.txt"
    mkdir -p "$stage_dir/etc/systemd/system/multi-user.target.wants" "$stage_dir/var/lib/orangepi5plus"
    ln -sfn /usr/lib/systemd/system/sshd.service "$stage_dir/etc/systemd/system/multi-user.target.wants/sshd.service"
    find "$stage_dir/etc/systemd/system" -type l \( -name '*systemd-networkd*' -o -lname '*systemd-networkd*' \) -delete
    find "$stage_dir/etc/systemd/system" -type l \( -name '*dhcpcd*' -o -lname '*dhcpcd*' \) -delete
    rm -f "$stage_dir/etc/systemd/network/en.network" "$stage_dir/etc/systemd/network/eth.network"
    ln -sfn /usr/lib/systemd/system/NetworkManager.service "$stage_dir/etc/systemd/system/multi-user.target.wants/NetworkManager.service"
    rm -f "$stage_dir/etc/systemd/system/multi-user.target.wants/iwd.service"
    ln -sfn /usr/lib/systemd/system/wpa_supplicant.service "$stage_dir/etc/systemd/system/multi-user.target.wants/wpa_supplicant.service"
    ln -sfn /usr/lib/systemd/system/systemd-resolved.service "$stage_dir/etc/systemd/system/multi-user.target.wants/systemd-resolved.service"
    ln -sfn /usr/lib/systemd/system/systemd-timesyncd.service "$stage_dir/etc/systemd/system/multi-user.target.wants/systemd-timesyncd.service"
    ln -sfn /usr/lib/systemd/system/systemd-oomd.service "$stage_dir/etc/systemd/system/multi-user.target.wants/systemd-oomd.service"
    mkdir -p "$stage_dir/etc/systemd/system/timers.target.wants"
    ln -sfn /usr/lib/systemd/system/logrotate.timer "$stage_dir/etc/systemd/system/timers.target.wants/logrotate.timer"
    ln -sfn /usr/lib/systemd/system/fstrim.timer "$stage_dir/etc/systemd/system/timers.target.wants/fstrim.timer"
    ln -sfn /usr/lib/systemd/system/paccache.timer "$stage_dir/etc/systemd/system/timers.target.wants/paccache.timer"
    mkdir -p "$stage_dir/etc/systemd/system/getty.target.wants"
    ln -sfn /usr/lib/systemd/system/serial-getty@.service "$stage_dir/etc/systemd/system/getty.target.wants/serial-getty@ttyS2.service"
    ln -sfn /etc/systemd/system/op5-firstboot.service "$stage_dir/etc/systemd/system/multi-user.target.wants/op5-firstboot.service"
    ln -sfn /etc/systemd/system/op5-grow-root.service "$stage_dir/etc/systemd/system/multi-user.target.wants/op5-grow-root.service"
    find "$stage_dir" -xdev -print0 | xargs -0 touch --no-dereference --date="@$SOURCE_DATE_EPOCH"
}

create_image() {
    local block_count block_size compressed_tmp final_path free_blocks image_tmp inode_count inode_times percentage_headroom reserved_blocks root_blocks root_end_sector root_partition_bytes usable_free
    ROOTFS_PAYLOAD_BYTES=$(du -sx --apparent-size --block-size=1 "$stage_dir" | cut -f1)
    percentage_headroom=$(((ROOTFS_PAYLOAD_BYTES * ROOTFS_HEADROOM_PERCENT + 99) / 100))
    ROOTFS_HEADROOM_BYTES=$ROOTFS_HEADROOM_MIN_BYTES
    if [ "$percentage_headroom" -gt "$ROOTFS_HEADROOM_BYTES" ]; then
        ROOTFS_HEADROOM_BYTES=$percentage_headroom
    fi
    root_partition_bytes=$((ROOTFS_PAYLOAD_BYTES + ROOTFS_HEADROOM_BYTES))
    root_partition_bytes=$((((root_partition_bytes + ROOTFS_SIZE_ALIGNMENT_BYTES - 1) / ROOTFS_SIZE_ALIGNMENT_BYTES) * ROOTFS_SIZE_ALIGNMENT_BYTES))
    rootfs_image="$build_dir/rootfs.ext4"
    while :; do
        root_blocks=$((root_partition_bytes / 4096))
        rm -f "$rootfs_image"
        truncate -s "$root_partition_bytes" "$rootfs_image"
        if E2FSPROGS_FAKE_TIME="$SOURCE_DATE_EPOCH" mkfs.ext4 -q -F -L rootfs -U "$ROOT_FS_UUID" \
            -E lazy_itable_init=0,lazy_journal_init=0,hash_seed="$ROOT_FS_UUID" -d "$stage_dir" "$rootfs_image"; then
            inode_count=$(dumpe2fs -h "$rootfs_image" 2>/dev/null | awk -F: '/^Inode count:/{gsub(/ /, "", $2); print $2}')
            inode_times="$build_dir/inode-times.debugfs"
            for field in atime ctime mtime crtime; do
                seq 1 "$inode_count" | sed "s/.*/set_inode_field <&> $field $SOURCE_DATE_EPOCH/"
            done > "$inode_times"
            E2FSPROGS_FAKE_TIME="$SOURCE_DATE_EPOCH" debugfs -w -f "$inode_times" "$rootfs_image" >/dev/null 2>&1
            E2FSPROGS_FAKE_TIME="$SOURCE_DATE_EPOCH" tune2fs -c 0 -i 0 "$rootfs_image" >/dev/null
            block_count=$(dumpe2fs -h "$rootfs_image" 2>/dev/null | awk -F: '/^Block count:/{gsub(/ /, "", $2); print $2}')
            free_blocks=$(dumpe2fs -h "$rootfs_image" 2>/dev/null | awk -F: '/^Free blocks:/{gsub(/ /, "", $2); print $2}')
            reserved_blocks=$(dumpe2fs -h "$rootfs_image" 2>/dev/null | awk -F: '/^Reserved block count:/{gsub(/ /, "", $2); print $2}')
            block_size=$(dumpe2fs -h "$rootfs_image" 2>/dev/null | awk -F: '/^Block size:/{gsub(/ /, "", $2); print $2}')
            usable_free=$(((free_blocks - reserved_blocks) * block_size))
            if [ "$usable_free" -ge "$ROOTFS_HEADROOM_BYTES" ]; then
                break
            fi
        fi
        root_partition_bytes=$((root_partition_bytes + ROOTFS_SIZE_ALIGNMENT_BYTES))
    done
    ROOTFS_PARTITION_BYTES=$root_partition_bytes
    ROOTFS_EXT4_USED_BYTES=$(((block_count - free_blocks) * block_size))
    ROOTFS_EXT4_USABLE_FREE_BYTES=$usable_free
    IMAGE_SIZE_BYTES=$((ROOT_START_SECTOR * 512 + ROOTFS_PARTITION_BYTES + IMAGE_TRAILING_SECTORS * 512))
    root_end_sector=$((ROOT_START_SECTOR + ROOTFS_PARTITION_BYTES / 512 - 1))
    image_tmp="$build_dir/$output_name.tmp"
    final_path="$repo_root/dist/$output_name"
    rm -f "$image_tmp"
    truncate -s "$IMAGE_SIZE_BYTES" "$image_tmp"
    sgdisk --clear --disk-guid="$DISK_GUID" \
        --new=1:"$ROOT_START_SECTOR":"$root_end_sector" --typecode=1:"$ROOT_FS_TYPE_GUID" \
        --change-name=1:rootfs --partition-guid=1:"$ROOT_PARTUUID" "$image_tmp" >/dev/null
    dd if="$build_dir/u-boot/u-boot-rockchip.bin" of="$image_tmp" bs=512 seek=64 conv=notrunc status=none
    dd if="$rootfs_image" of="$image_tmp" bs=512 seek="$ROOT_START_SECTOR" conv=notrunc,sparse status=none
    mkdir -p "$repo_root/dist"
    mv "$image_tmp" "$final_path.tmp"
    mv "$final_path.tmp" "$final_path"
    chmod 0644 "$final_path"
    compressed_tmp="$build_dir/$output_name.zst.tmp"
    rm -f "$compressed_tmp"
    zstd -q -T1 -"$IMAGE_ZSTD_LEVEL" -f "$final_path" -o "$compressed_tmp"
    mv "$compressed_tmp" "$final_path.zst.tmp"
    mv "$final_path.zst.tmp" "$final_path.zst"
    chmod 0644 "$final_path.zst"
    install -m 0644 "$build_dir/u-boot/u-boot-rockchip.bin" "$repo_root/dist/u-boot-rockchip.bin"
    install -m 0644 "$build_dir/u-boot/u-boot.itb" "$repo_root/dist/u-boot.itb"
    (cd "$repo_root/dist" && sha256sum "$output_name" > "$output_name.sha256")
    (cd "$repo_root/dist" && sha256sum "$output_name.zst" > "$output_name.zst.sha256")
    RAW_APPARENT_BYTES=$(stat -c %s "$final_path")
    RAW_SPARSE_BYTES=$(( $(stat -c %b "$final_path") * 512 ))
    COMPRESSED_BYTES=$(stat -c %s "$final_path.zst")
    {
        printf 'raw_apparent_bytes=%s\n' "$RAW_APPARENT_BYTES"
        printf 'raw_sparse_bytes=%s\n' "$RAW_SPARSE_BYTES"
        printf 'compressed_bytes=%s\n' "$COMPRESSED_BYTES"
        printf 'rootfs_payload_bytes=%s\n' "$ROOTFS_PAYLOAD_BYTES"
        printf 'rootfs_ext4_used_bytes=%s\n' "$ROOTFS_EXT4_USED_BYTES"
        printf 'rootfs_usable_free_bytes=%s\n' "$ROOTFS_EXT4_USABLE_FREE_BYTES"
        printf 'rootfs_partition_bytes=%s\n' "$ROOTFS_PARTITION_BYTES"
    } > "$repo_root/dist/image-measurements.txt"
}

write_manifest() {
    local manifest="$repo_root/dist/build-manifest.txt"
    {
        printf 'image=%s\n' "$output_name"
        printf 'image_size_bytes=%s\n' "$(stat -c %s "$repo_root/dist/$output_name")"
        cat "$repo_root/dist/image-measurements.txt"
        printf 'source_date_epoch=%s\n' "$SOURCE_DATE_EPOCH"
        printf 'rootfs_date=%s\nrootfs_sha256=%s\nrootfs_signer=%s\n' "$ROOTFS_DATE" "$ROOTFS_SHA256" "$ALARM_SIGNER_FINGERPRINT"
        printf 'linux=%s\nlinux_sha256=%s\n' "$LINUX_VERSION" "$LINUX_SHA256"
        printf 'u_boot=%s\nu_boot_commit=%s\n' "$UBOOT_VERSION" "$UBOOT_COMMIT"
        printf 'trusted_firmware_a=%s\ntrusted_firmware_a_commit=%s\n' "$ATF_VERSION" "$ATF_COMMIT"
        printf 'rkbin_commit=%s\nrkbin_ddr=%s\n' "$RKBIN_COMMIT" "$RKBIN_DDR"
        printf 'rkbin_ddr_sha256=%s\n' "$(sha256sum "$source_dir/rkbin/$RKBIN_DDR" | cut -d' ' -f1)"
        printf 'container_base=%s\n' 'debian@sha256:88200866dfff7ea7f5cbcb6ec7c8a701889efe6fe859fe64d6990e4b07ea4171'
        printf 'gcc=%s\n' "$(gcc -dumpfullversion)"
        printf 'binutils=%s\n' "$(ld --version | head -1)"
        printf 'make=%s\n' "$(make --version | head -1)"
        printf 'package_lock_sha256=%s\n' "$(sha256sum "$repo_root/config/packages.lock" | cut -d' ' -f1)"
        printf 'packages_sha256=%s\n' "$(sha256sum "$repo_root/config/packages.txt" | cut -d' ' -f1)"
        printf 'package_signers=%s\n' "$(paste -sd, "$repo_root/config/package-signers.txt")"
        (cd "$repo_root/dist" && sha256sum "$output_name" "$output_name.zst" u-boot-rockchip.bin u-boot.itb)
    } > "$manifest"
    cp "$source_dir/rkbin/LICENSE" "$repo_root/dist/rkbin-LICENSE"
}

if [ "${KERNEL_ONLY:-0}" != 1 ]; then
    prepare_sources
    build_atf 2>&1 | tee "$log_dir/atf.log"
    build_uboot 2>&1 | tee "$log_dir/u-boot.log"
    build_linux 2>&1 | tee "$log_dir/linux.log"
    create_kernel_package 2>&1 | tee "$log_dir/kernel-package.log"
    create_rootfs 2>&1 | tee "$log_dir/rootfs.log"
    create_image 2>&1 | tee "$log_dir/image.log"
    write_manifest
    "$repo_root/scripts/inspect.sh" "$repo_root/dist/$output_name" | tee "$repo_root/dist/inspection.txt"
fi
