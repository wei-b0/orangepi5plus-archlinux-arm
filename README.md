# Arch Linux ARM for Orange Pi 5 Plus

A directly flashable Arch Linux ARM image for the **LPDDR4X Orange Pi 5 Plus** (Rockchip RK3588). It is intended as a normal AArch64 Arch base for board use and remote coding workloads.

This image targets the Orange Pi **5 Plus** specifically. It is not a generic Orange Pi 5/5B image.

**Board:** Orange Pi 5 Plus · **Architecture:** AArch64 · **Kernel:** Linux 6.18.50 · **Image status:** Build-validated; physical NVMe cold-boot validation pending

## Current artifacts

The current release is under `dist/`:

| File | Use |
| --- | --- |
| `orangepi5plus-archlinuxarm.img` | Raw image for `dd`, Balena Etcher, or Raspberry Pi Imager |
| `orangepi5plus-archlinuxarm.img.zst` | Compressed raw image for streaming with `zstd -dc` |
| `*.sha256` | SHA-256 checksums |
| `build-manifest.txt` | Pinned sources, toolchain, packages, and component hashes |
| `image-measurements.txt` | Image and filesystem measurements |
| `inspection.txt` | Static validation output |

Current checksums:

```text
8f60b6f62546ee3d517aaa3fa21f6a99878d08fde71c0a3bcf1ff90188ac346a  orangepi5plus-archlinuxarm.img
9d177813727d192c788f0d97615283c54c8b69f07f91ffd7410be2173da37ecb  orangepi5plus-archlinuxarm.img.zst
```

The checksum files in `dist/` are authoritative after every rebuild.

## Platform baseline

| Component | Selected baseline |
| --- | --- |
| Userspace | Official Arch Linux ARM AArch64 rootfs dated 2026-08-05 |
| Kernel | Mainline Linux 6.18.50, installed as `6.18.50-orangepi5plus` |
| Device tree | Mainline `rk3588-orangepi-5-plus.dtb` |
| U-Boot | Mainline v2026.07, `orangepi-5-plus-rk3588_defconfig` |
| Trusted firmware | Trusted Firmware-A v2.14.0, built for RK3588 |
| DDR initialization | Rockchip DDR v1.18 from pinned rkbin commit |
| Boot flow | GPT, ext4 root, extlinux, `/boot` inside the root filesystem |

The RK3588 DDR binary is the required non-mainline boot component. Its exact source commit, path, checksum, and license are recorded in `dist/build-manifest.txt` and `dist/rkbin-LICENSE`. No vendor kernel, miniloader, OP-TEE image, or out-of-tree Wi-Fi driver is used.

The image includes systemd, OpenSSH, NetworkManager, `wpa_supplicant`, resolved, timesyncd, wired DHCP, persistent bounded journald, Zstandard zram, first-boot identity generation, first-boot root expansion, serial and HDMI consoles, Panthor/Mali support, and the remote-development package baseline.

## Flash a microSD card

Writing an image erases the selected device. Select the whole card, never a partition.

### Linux

Identify the card:

```sh
lsblk -o NAME,SIZE,MODEL,TRAN,MOUNTPOINTS
```

Verify and flash the raw image:

```sh
(cd dist && sha256sum --check orangepi5plus-archlinuxarm.img.sha256)
sudo umount /dev/sdX?* 2>/dev/null || true
sudo dd if=dist/orangepi5plus-archlinuxarm.img of=/dev/sdX bs=4M status=progress conv=fsync
sync
```

Or verify and stream the compressed image:

```sh
(cd dist && sha256sum --check orangepi5plus-archlinuxarm.img.zst.sha256)
zstd -dc -- dist/orangepi5plus-archlinuxarm.img.zst | \
  sudo dd of=/dev/sdX bs=4M status=progress conv=fsync
sync
```

Replace `/dev/sdX` with the whole card. Some systems expose removable media as `/dev/mmcblkN`.

### macOS

Find the card, unmount it, write to the raw device, then eject it:

```sh
diskutil list
diskutil unmountDisk /dev/diskN
(cd dist && shasum -a 256 --check orangepi5plus-archlinuxarm.img.sha256)
sudo dd if=dist/orangepi5plus-archlinuxarm.img of=/dev/rdiskN bs=4m
sync
diskutil eject /dev/diskN
```

### Etcher or Raspberry Pi Imager

Choose `dist/orangepi5plus-archlinuxarm.img` as a custom image and flash the microSD card. Do not apply Raspberry Pi OS-specific settings.

## First boot

The default hostname is `orangepi-agent`. The first boot generates the machine ID, SSH host keys, pacman keyring, NVMe host identity, and other per-board state. These are intentionally not baked into the image.

| User | Initial password | Access |
| --- | --- | --- |
| `alarm` | `alarm` | Local login, SSH, and password-authenticated `sudo` |
| `root` | `root` | Local login; root SSH login disabled |

Change both passwords immediately:

```sh
passwd
sudo passwd root
```

The published image is intentionally small: immediately after flashing, the GPT root partition is about 3.6 GiB even when the card or SSD is much larger. This keeps downloads and writes small. On the first boot, `op5-grow-root.service` moves the backup GPT header, grows the root partition, and grows ext4 to fill the available device:

```sh
systemctl status op5-grow-root
findmnt /
df -h /
lsblk
```

The service is idempotent and does not block login if expansion fails. If the root filesystem still reports about 3.6 GiB after the first boot, run the expansion manually against the parent disk, not the root partition:

```sh
root_device=$(findmnt -n -o SOURCE /)
parent_disk=/dev/$(lsblk -n -o PKNAME "$root_device")
sudo systemd-repart --dry-run=no --growfs=yes "$parent_disk"
df -h /
lsblk
```

Use an SD card or SSD larger than the 3.64 GiB image; 8 GiB or larger is recommended for normal headroom.

SSH, NetworkManager, resolved, timesyncd, journald, and the first-boot services are enabled. The serial console is `ttyS2` at 1500000 baud; HDMI console output remains enabled.

## Ethernet and TL-WN725N Wi-Fi

NetworkManager manages both Ethernet interfaces and Wi-Fi. Wired interfaces use DHCP automatically. `wpa_supplicant` is the active Wi-Fi backend; `iwd.service` is not enabled.

Confirmed USB adapter:

| Item | Value |
| --- | --- |
| Adapter | TP-Link TL-WN725N |
| USB ID | `0bda:8179` |
| Chipset | Realtek RTL8188EUS |
| Driver | In-kernel `rtl8xxxu` |
| Firmware | `/usr/lib/firmware/rtlwifi/rtl8188eufw.bin` |

The module is installed with normal udev aliases and listed in `/etc/modules-load.d/rtl8xxxu.conf`. No Wi-Fi credentials or connection profiles are embedded.

```sh
nmcli device wifi list
sudo nmcli device wifi connect "SSID" password "PASSWORD"
```

Use `sudo nmcli --ask device wifi connect "SSID"` to avoid putting a password in shell history. Diagnostics:

```sh
lsusb
rfkill
ip link show
nmcli device status
journalctl -b -u NetworkManager -u wpa_supplicant
dmesg | grep -Ei 'rtl8|firmware|wlan'
```

## Use the image as an NVMe root

The image contains the matching kernel, DTB, modules, extlinux configuration, and fixed root PARTUUID. You can write the compressed image to NVMe while temporarily booted from the old SD card.

Identify the NVMe device first. It is normally `/dev/nvme0n1`:

```sh
lsblk -o NAME,SIZE,MODEL,TRAN,MOUNTPOINTS
```

The next command erases that NVMe device. Unmount it and stream the image from the USB drive:

```sh
sudo umount /dev/nvme0n1p1 2>/dev/null || true
set -o pipefail
zstd -dc -- /run/media/alarm/USB/orangepi5plus-archlinuxarm.img.zst | \
  sudo dd of=/dev/nvme0n1 bs=4M status=progress conv=fsync
sync
sudo partprobe /dev/nvme0n1
```

Verify the root identity:

```sh
lsblk -f /dev/nvme0n1
sudo blkid /dev/nvme0n1p1
```

The root PARTUUID is `93b3f00d-5c7b-4ed7-9c2f-d9e93b995c01`. Shut down, remove the SD card, and power on:

```sh
sudo poweroff
```

The board's existing SPI or eMMC-selected U-Boot must scan NVMe and load `/boot/extlinux/extlinux.conf` from it. The image does not rewrite SPI or eMMC. If the board continues to select SD, remove the SD card or select NVMe in U-Boot. After boot:

```sh
uname -r
findmnt /
sudo nvme list
systemctl status op5-grow-root
```

The built-in NVMe core and block driver remove the previous pre-mount module-loading failure. U-Boot NVMe discovery still requires board-specific physical validation.

## UART and recovery

Use a **3.3 V UART adapter**, **1500000 baud**, **8N1**. Connect ground, RX, and TX only; never connect the adapter power pin.

| Last output | Inspect |
| --- | --- |
| DDR, SPL, or no output | Power, SD detection, DDR binary, raw U-Boot placement |
| TF-A or BL31 | Trusted-firmware handoff and DDR initialization |
| U-Boot banner or prompt | Boot source, NVMe scan, extlinux files |
| `Starting kernel` | Kernel, DTB, root PARTUUID, PCIe/NVMe, filesystem |
| systemd or login | Network, first-boot services, SSH, expansion |

Read-only U-Boot checks:

```text
nvme scan
nvme info
part list nvme 0
ext4ls nvme 0:1 /boot/extlinux
```

An existing SPI/eMMC loader may take priority over removable media. Do not erase SPI or eMMC as a recovery step. Disconnect power before removing removable eMMC hardware. If Linux boots with the wrong root, compare `/boot/extlinux/extlinux.conf` with:

```sh
sgdisk --info=1 /dev/nvme0n1
```

Reflash the complete image if GPT, filesystem, or bootloader regions are damaged.

## Build from source

Build on Linux with Docker Engine, Docker Buildx, and AArch64 container execution. The container and Debian packages are pinned in `Dockerfile`. Verified Arch rootfs, package archives, signing keys, repository databases, and source archives are retained under `downloads/`. Keep Docker storage on Linux-backed storage where possible and reserve about 20 GB for one clean build.

```sh
./build.sh fetch
./build.sh build
./build.sh inspect
```

Limit compilation parallelism when memory is limited:

```sh
JOBS=4 ./build.sh build
```

The normal build reuses verified inputs and the `orangepi5plus-arch-build` Docker volume. Publication into `dist/` is atomic. Root partition capacity is calculated from installed rootfs usage plus at least 768 MiB or 25% free headroom, aligned to 64 MiB.

For the targeted NVMe kernel rebuild, without rebuilding U-Boot or TF-A:

```sh
./build.sh rebuild-kernel-nvme
./build.sh inspect
```

This keeps Linux at 6.18.50 and builds the RK3588 PCIe host, PCIe3 PHY, NVMe core, NVMe block driver, and EXT4 into the kernel. Wi-Fi, Panthor, DTB, U-Boot, TF-A, DDR firmware, and boot layout remain unchanged.

Refresh the frozen Arch package set deliberately:

```sh
./build.sh refresh-packages
./build.sh build
./build.sh inspect
```

Package versions, repositories, signatures, hashes, and signer fingerprints are retained in `config/packages.lock` and `downloads/`. Builds never silently resolve against moving repositories.

The optional two-build check is:

```sh
./build.sh verify-reproducible
```

Do not claim byte reproducibility for an artifact until that command succeeds for the same inputs. `./build.sh clean` removes generated build state and `dist/`; use it only when that is intended.

## Image measurements

Current values from `dist/image-measurements.txt`:

| Measurement | Bytes | Approximate |
| --- | ---: | ---: |
| Raw apparent image | 3,910,139,904 | 3.64 GiB |
| Sparse allocation | 3,450,683,392 | 3.21 GiB |
| Compressed image | 890,741,369 | 850 MiB |
| Rootfs payload | 2,844,880,916 | 2.65 GiB |
| Ext4 used before expansion | 2,879,827,968 | 2.68 GiB |
| Ext4 usable free space | 817,872,896 | 780 MiB |
| Root partition | 3,892,314,112 | 3.62 GiB |

The image can be written to a larger card or SSD; the first-boot service grows the root partition and filesystem.

## Boot layout and validation

| Region | Location |
| --- | ---: |
| Combined Rockchip/U-Boot image | 32 KiB, LBA 64 |
| U-Boot FIT payload | 8 MiB, LBA 16384 |
| Root partition start | 16 MiB, LBA 32768 |

`./build.sh inspect` verifies GPT CRCs, bootloader bytes, FIT data, ext4 integrity, UUIDs, extlinux, DTB compatibility, required kernel settings, NVMe/Wi-Fi module metadata, firmware, packages, enabled services, and absence of generated secrets.

Physical cold-boot checks are still required for SD and NVMe boot, RAM detection, both Ethernet ports, Wi-Fi association, SSH, HDMI, UART, Panthor, expansion, and reboot. Mainline RK3588 multimedia, camera, NPU, and accelerator support is not claimed to match a vendor BSP.

## Provenance

Linux, U-Boot, Trusted Firmware-A, Arch Linux ARM, and Rockchip firmware retain their upstream licenses. Exact source revisions, archive hashes, package signer fingerprints, firmware checksums, and the container digest are recorded in `dist/build-manifest.txt`.
