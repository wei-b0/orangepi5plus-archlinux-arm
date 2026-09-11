#!/usr/bin/env bash
set -euo pipefail

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
source "$repo_root/config/versions.env"
image=${1:-$repo_root/dist/$IMAGE_NAME}
tmp_dir=$(mktemp -d)
trap 'rm -rf "$tmp_dir"' EXIT

test -f "$image"
image_size_bytes=$(stat -c %s "$image")
test "$((image_size_bytes % 512))" -eq 0
image_sectors=$((image_size_bytes / 512))
expected_root_end=$((image_sectors - IMAGE_TRAILING_SECTORS - 1))
sgdisk --verify "$image"
partition_info=$(sgdisk --info=1 "$image")
grep -qi "Partition unique GUID: $ROOT_PARTUUID" <<< "$partition_info"
grep -q "First sector: $ROOT_START_SECTOR" <<< "$partition_info"
grep -q "Last sector: $expected_root_end" <<< "$partition_info"
grep -q "Partition name: 'rootfs'" <<< "$partition_info"
root_end_sector=$(awk '/Last sector:/{print $3}' <<< "$partition_info")
partition_sectors=$((root_end_sector - ROOT_START_SECTOR + 1))
test "$((partition_sectors % 8))" -eq 0

boot_size=$(stat -c %s "$repo_root/dist/u-boot-rockchip.bin")
dd if="$image" of="$tmp_dir/u-boot.bin" bs=512 skip=64 count=$(((boot_size + 511) / 512)) status=none
cmp -n "$boot_size" "$repo_root/dist/u-boot-rockchip.bin" "$tmp_dir/u-boot.bin"
fit_magic=$(dd if="$image" bs=1 skip=$((8 * 1024 * 1024)) count=4 status=none | xxd -p)
test "$fit_magic" = d00dfeed

root_blocks=$((partition_sectors / 8))
dd if="$image" of="$tmp_dir/rootfs.ext4" bs=4096 skip=$((ROOT_START_SECTOR / 8)) count="$root_blocks" conv=sparse status=none
e2fsck -fn "$tmp_dir/rootfs.ext4"
test "$(blkid -s UUID -o value "$tmp_dir/rootfs.ext4")" = "$ROOT_FS_UUID"

debugfs -R "dump /boot/extlinux/extlinux.conf $tmp_dir/extlinux.conf" "$tmp_dir/rootfs.ext4" >/dev/null 2>&1
debugfs -R "dump /boot/config-orangepi5plus $tmp_dir/kernel.config" "$tmp_dir/rootfs.ext4" >/dev/null 2>&1
debugfs -R "dump /etc/hostname $tmp_dir/hostname" "$tmp_dir/rootfs.ext4" >/dev/null 2>&1
debugfs -R "dump /etc/NetworkManager/conf.d/20-orangepi-agent.conf $tmp_dir/networkmanager.conf" "$tmp_dir/rootfs.ext4" >/dev/null 2>&1
debugfs -R "dump /etc/NetworkManager/conf.d/99-wifi-backend.conf $tmp_dir/wifi-backend.conf" "$tmp_dir/rootfs.ext4" >/dev/null 2>&1
debugfs -R "dump /etc/modules-load.d/rtl8xxxu.conf $tmp_dir/rtl8xxxu.conf" "$tmp_dir/rootfs.ext4" >/dev/null 2>&1
debugfs -R "dump /etc/iwd/main.conf $tmp_dir/iwd.conf" "$tmp_dir/rootfs.ext4" >/dev/null 2>&1
debugfs -R "dump /etc/systemd/journald.conf.d/20-orangepi-agent.conf $tmp_dir/journald.conf" "$tmp_dir/rootfs.ext4" >/dev/null 2>&1
debugfs -R "dump /etc/systemd/zram-generator.conf $tmp_dir/zram-generator.conf" "$tmp_dir/rootfs.ext4" >/dev/null 2>&1
debugfs -R "dump /etc/ssh/sshd_config.d/20-orangepi5plus.conf $tmp_dir/sshd.conf" "$tmp_dir/rootfs.ext4" >/dev/null 2>&1
debugfs -R "dump /var/lib/pacman/local/linux-orangepi5plus-$KERNEL_PACKAGE_VERSION/desc $tmp_dir/kernel-desc" "$tmp_dir/rootfs.ext4" >/dev/null 2>&1
grep -q "root=PARTUUID=$ROOT_PARTUUID" "$tmp_dir/extlinux.conf"
grep -q 'console=ttyS2,1500000n8' "$tmp_dir/extlinux.conf"
grep -qx 'orangepi-agent' "$tmp_dir/hostname"
grep -q 'dns=systemd-resolved' "$tmp_dir/networkmanager.conf"
grep -q 'wifi.backend=wpa_supplicant' "$tmp_dir/wifi-backend.conf"
grep -qx 'rtl8xxxu' "$tmp_dir/rtl8xxxu.conf"
grep -q 'EnableNetworkConfiguration=false' "$tmp_dir/iwd.conf"
grep -q 'Storage=persistent' "$tmp_dir/journald.conf"
grep -q 'SystemMaxUse=256M' "$tmp_dir/journald.conf"
grep -q 'zram-size=min(ram / 2, 4096)' "$tmp_dir/zram-generator.conf"
grep -q 'PermitRootLogin no' "$tmp_dir/sshd.conf"
grep -A1 '^%INSTALLDATE%$' "$tmp_dir/kernel-desc" | grep -q "$SOURCE_DATE_EPOCH"
grep -q '^CONFIG_RTL8XXXU=m$' "$tmp_dir/kernel.config"
grep -q '^CONFIG_MAC80211=m$' "$tmp_dir/kernel.config"
grep -q '^CONFIG_CFG80211=m$' "$tmp_dir/kernel.config"
grep -q '^CONFIG_ZRAM=m$' "$tmp_dir/kernel.config"
grep -q '^CONFIG_DRM_PANTHOR=m$' "$tmp_dir/kernel.config"
grep -q '^CONFIG_FW_LOADER_COMPRESS_XZ=y$' "$tmp_dir/kernel.config"
grep -q '^CONFIG_FW_LOADER_COMPRESS_ZSTD=y$' "$tmp_dir/kernel.config"
grep -q '^CONFIG_PCIE_ROCKCHIP_DW_HOST=y$' "$tmp_dir/kernel.config"
grep -q '^CONFIG_PHY_ROCKCHIP_SNPS_PCIE3=y$' "$tmp_dir/kernel.config"
grep -q '^CONFIG_NVME_CORE=y$' "$tmp_dir/kernel.config"
grep -q '^CONFIG_BLK_DEV_NVME=y$' "$tmp_dir/kernel.config"
grep -q '^CONFIG_EXT4_FS=y$' "$tmp_dir/kernel.config"
while IFS= read -r setting; do
    grep -qx "$setting" "$tmp_dir/kernel.config"
done <<'EOF'
CONFIG_SECURITY_LANDLOCK=y
CONFIG_SECURITY_YAMA=y
CONFIG_SECURITY_DMESG_RESTRICT=y
CONFIG_HARDENED_USERCOPY=y
CONFIG_FORTIFY_SOURCE=y
CONFIG_SLAB_FREELIST_RANDOM=y
CONFIG_SLAB_FREELIST_HARDENED=y
CONFIG_INIT_ON_ALLOC_DEFAULT_ON=y
CONFIG_RANDOMIZE_KSTACK_OFFSET_DEFAULT=y
CONFIG_MODULE_COMPRESS=y
CONFIG_MODULE_COMPRESS_ZSTD=y
CONFIG_MODULE_COMPRESS_ALL=y
CONFIG_CFS_BANDWIDTH=y
CONFIG_PSI=y
CONFIG_TASK_DELAY_ACCT=y
CONFIG_BINFMT_MISC=m
CONFIG_NF_TABLES=m
CONFIG_NF_NAT=m
CONFIG_NFT_CT=m
CONFIG_NFT_NAT=m
CONFIG_NFT_MASQ=m
CONFIG_NFT_REJECT_INET=m
CONFIG_NFT_COMPAT=m
CONFIG_IPVLAN=m
CONFIG_VXLAN=m
CONFIG_DUMMY=m
CONFIG_WIREGUARD=m
CONFIG_USB_NET_RNDIS_HOST=m
CONFIG_USB_UAS=m
CONFIG_DM_CRYPT=m
CONFIG_EXFAT_FS=m
CONFIG_NLS_UTF8=m
CONFIG_HIDRAW=y
CONFIG_INPUT_UINPUT=m
CONFIG_SND_USB_AUDIO=m
CONFIG_KPROBES=y
CONFIG_KPROBE_EVENTS=y
CONFIG_UPROBES=y
CONFIG_UPROBE_EVENTS=y
CONFIG_FTRACE=y
CONFIG_FUNCTION_TRACER=y
CONFIG_DYNAMIC_FTRACE=y
CONFIG_BPF_EVENTS=y
EOF
grep -qx '# CONFIG_OVERLAY_FS_REDIRECT_ALWAYS_FOLLOW is not set' "$tmp_dir/kernel.config"

dtb=/boot/dtbs/orangepi5plus/rockchip/rk3588-orangepi-5-plus.dtb
debugfs -R "dump $dtb $tmp_dir/board.dtb" "$tmp_dir/rootfs.ext4" >/dev/null 2>&1
fdtget "$tmp_dir/board.dtb" / compatible | grep -q 'xunlong,orangepi-5-plus'

kernel_release=$(debugfs -R 'ls -p /usr/lib/modules' "$tmp_dir/rootfs.ext4" 2>/dev/null | awk -F/ '/orangepi5plus/{print $6; exit}')
test -n "$kernel_release"
debugfs -R "dump /usr/lib/modules/$kernel_release/modules.alias $tmp_dir/modules.alias" "$tmp_dir/rootfs.ext4" >/dev/null 2>&1
grep -Eqi 'usb:v0BDAp8179.*rtl8xxxu' "$tmp_dir/modules.alias"
debugfs -R "ls -p /usr/lib/modules/$kernel_release/kernel/drivers/net/wireless/realtek/rtl8xxxu" "$tmp_dir/rootfs.ext4" 2>/dev/null | grep -Eq 'rtl8xxxu\.ko(\.zst)?'
for module_path in \
    /usr/lib/modules/$kernel_release/kernel/drivers/block/zram/zram.ko \
    /usr/lib/modules/$kernel_release/kernel/drivers/input/misc/uinput.ko \
    /usr/lib/modules/$kernel_release/kernel/drivers/net/wireguard/wireguard.ko \
    /usr/lib/modules/$kernel_release/kernel/drivers/usb/storage/uas.ko \
    /usr/lib/modules/$kernel_release/kernel/fs/exfat/exfat.ko \
    /usr/lib/modules/$kernel_release/kernel/net/netfilter/nf_tables.ko; do
    if ! debugfs -R "stat $module_path" "$tmp_dir/rootfs.ext4" 2>&1 | grep -q 'Type: regular'; then
        debugfs -R "stat $module_path.zst" "$tmp_dir/rootfs.ext4" 2>&1 | grep -q 'Type: regular'
    fi
done
debugfs -R 'ls -p /usr/lib/firmware/rtlwifi' "$tmp_dir/rootfs.ext4" 2>/dev/null | grep -q 'rtl8188eufw.bin'
debugfs -R 'ls -p /usr/lib/firmware/arm/mali/arch10.8' "$tmp_dir/rootfs.ext4" 2>/dev/null | grep -q 'mali_csffw.bin'
debugfs -R 'stat /usr/bin/rfkill' "$tmp_dir/rootfs.ext4" 2>&1 | grep -q 'Type: regular'
debugfs -R 'ls -p /var/lib/pacman/local' "$tmp_dir/rootfs.ext4" 2>/dev/null > "$tmp_dir/pacman-local"
while IFS= read -r package_name; do
    grep -q "/$package_name-" "$tmp_dir/pacman-local"
done < "$repo_root/config/packages.txt"
for service in sshd NetworkManager wpa_supplicant systemd-resolved systemd-timesyncd systemd-oomd op5-firstboot op5-grow-root; do
    debugfs -R "stat /etc/systemd/system/multi-user.target.wants/$service.service" "$tmp_dir/rootfs.ext4" 2>&1 | grep -q 'Type: symlink'
done
debugfs -R 'stat /etc/systemd/system/multi-user.target.wants/iwd.service' "$tmp_dir/rootfs.ext4" 2>&1 | grep -q 'File not found'
for timer in logrotate fstrim paccache; do
    debugfs -R "stat /etc/systemd/system/timers.target.wants/$timer.timer" "$tmp_dir/rootfs.ext4" 2>&1 | grep -q 'Type: symlink'
done
for networkd_path in \
    /etc/systemd/system/multi-user.target.wants/systemd-networkd.service \
    /etc/systemd/system/dbus-org.freedesktop.network1.service \
    /etc/systemd/system/network-online.target.wants/systemd-networkd-wait-online.service \
    /etc/systemd/system/sockets.target.wants/systemd-networkd.socket \
    /etc/systemd/system/sockets.target.wants/systemd-networkd-resolve-hook.socket \
    /etc/systemd/system/sockets.target.wants/systemd-networkd-varlink.socket \
    /etc/systemd/network/en.network \
    /etc/systemd/network/eth.network; do
    debugfs -R "stat $networkd_path" "$tmp_dir/rootfs.ext4" 2>&1 | grep -q 'File not found'
done
debugfs -R "stat /var/lib/pacman/local/linux-orangepi5plus-$KERNEL_PACKAGE_VERSION/mtree" "$tmp_dir/rootfs.ext4" 2>&1 | grep -q 'Type: regular'
debugfs -R 'ls -p /etc/ssh' "$tmp_dir/rootfs.ext4" 2>/dev/null > "$tmp_dir/ssh-files"
! grep -q 'ssh_host_' "$tmp_dir/ssh-files"
debugfs -R "dump /etc/machine-id $tmp_dir/machine-id" "$tmp_dir/rootfs.ext4" >/dev/null 2>&1
test ! -s "$tmp_dir/machine-id"
debugfs -R 'stat /dev/null' "$tmp_dir/rootfs.ext4" 2>&1 | grep -q 'Type: character special'
debugfs -R 'stat /etc/nvme/hostid' "$tmp_dir/rootfs.ext4" 2>&1 | grep -q 'File not found'
debugfs -R 'stat /etc/nvme/hostnqn' "$tmp_dir/rootfs.ext4" 2>&1 | grep -q 'File not found'
debugfs -R 'stat /var/cache/ldconfig/aux-cache' "$tmp_dir/rootfs.ext4" 2>&1 | grep -q 'File not found'
block_count=$(dumpe2fs -h "$tmp_dir/rootfs.ext4" 2>/dev/null | awk -F: '/^Block count:/{gsub(/ /, "", $2); print $2}')
free_blocks=$(dumpe2fs -h "$tmp_dir/rootfs.ext4" 2>/dev/null | awk -F: '/^Free blocks:/{gsub(/ /, "", $2); print $2}')
block_size=$(dumpe2fs -h "$tmp_dir/rootfs.ext4" 2>/dev/null | awk -F: '/^Block size:/{gsub(/ /, "", $2); print $2}')
rootfs_ext4_used_bytes=$(((block_count - free_blocks) * block_size))
if [ -f "$image.zst" ]; then
    zstd -q -t "$image.zst"
    test "$(zstd -q -dc "$image.zst" | sha256sum | cut -d' ' -f1)" = "$(sha256sum "$image" | cut -d' ' -f1)"
fi
printf 'image=%s\n' "$image"
printf 'image_sha256=%s\n' "$(sha256sum "$image" | cut -d' ' -f1)"
printf 'image_size_bytes=%s\n' "$image_size_bytes"
printf 'raw_sparse_bytes=%s\n' "$(( $(stat -c %b "$image") * 512 ))"
if [ -f "$image.zst" ]; then printf 'compressed_bytes=%s\n' "$(stat -c %s "$image.zst")"; fi
printf 'rootfs_ext4_used_bytes=%s\n' "$rootfs_ext4_used_bytes"
printf 'partition_start_lba=%s\n' "$ROOT_START_SECTOR"
printf 'u_boot_offset_bytes=32768\nfit_offset_bytes=8388608\n'
printf 'root_uuid=%s\nroot_partuuid=%s\n' "$ROOT_FS_UUID" "$ROOT_PARTUUID"
printf 'kernel_release=%s\n' "$kernel_release"
printf 'dt_compatible=%s\n' "$(fdtget "$tmp_dir/board.dtb" / compatible)"
printf 'validation=PASS\n'
