# Arch Linux ARM for Orange Pi 5 Plus

A pinned, directly flashable Arch Linux ARM image for the **LPDDR4X Orange Pi 5 Plus** (RK3588). The image stays close to a normal Arch Linux ARM installation while providing the board-specific boot chain, kernel, firmware, networking, and first-boot setup required for a useful headless system.

The generated image can be written to a microSD card with `dd`, Balena Etcher, or Raspberry Pi Imager. It contains its own SD boot chain and does not install or modify SPI flash or eMMC.

## Platform support

| Component | Version or implementation |
|---|---|
| Userspace | Official Arch Linux ARM AArch64 root filesystem dated 2026-08-05 |
| Kernel | Mainline Linux 6.18.50, release `6.18.50-orangepi5plus` |
| Device tree | Mainline `rk3588-orangepi-5-plus.dts` |
| Bootloader | Mainline U-Boot 2026.07, `orangepi-5-plus-rk3588_defconfig` |
| Trusted firmware | Trusted Firmware-A 2.14.0, built from source for RK3588 |
| DDR initialization | Rockchip DDR v1.18 from pinned `rkbin` commit `f43a462e7a1429a9d407ae52b4745033034a6cf9` |
| Boot menu | extlinux |

The Rockchip DDR initialization binary is the only required proprietary boot component. RK3588 cannot initialize DRAM without it. The build records its exact source revision, checksum, path, and license. No vendor kernel, miniloader, OP-TEE image, or out-of-tree Wi-Fi driver is used.

The image includes:

- systemd, OpenSSH, NetworkManager, `wpa_supplicant`, resolved, and timesyncd
- wired DHCP on both Ethernet interfaces
- a remote-development toolset including Git, Git LFS, `base-devel`, tmux, ripgrep, editors, archives, and diagnostics
- persistent journald storage with bounded disk usage
- Zstandard-compressed zram swap, capped at 4 GiB
- serial and HDMI consoles
- automatic root-partition and filesystem expansion on first boot
- the mainline Panthor driver and Mali firmware

This project targets the **Orange Pi 5 Plus** specifically. Images for the Orange Pi 5, 5B, or other RK3588 boards are not interchangeable.

## Flash an SD card

Use the whole removable device, not one of its partitions. Writing the image destroys the existing contents of the selected card.

### Linux

1. Identify the card with `lsblk`.
2. Unmount any mounted partitions.
3. Verify and write the raw image, replacing `/dev/sdX` with the whole card:

```sh
(cd dist && sha256sum --check orangepi5plus-archlinuxarm.img.sha256)
sudo dd if=dist/orangepi5plus-archlinuxarm.img of=/dev/sdX bs=4M status=progress conv=fsync
```

The compressed artifact can be verified and streamed directly to the card:

```sh
(cd dist && sha256sum --check orangepi5plus-archlinuxarm.img.zst.sha256)
zstd -dc dist/orangepi5plus-archlinuxarm.img.zst | sudo dd of=/dev/sdX bs=4M status=progress conv=fsync
```

### macOS

1. Find the card with `diskutil list`.
2. Unmount it with `diskutil unmountDisk /dev/diskN`.
3. Verify and write to the corresponding raw whole device:

```sh
(cd dist && shasum -a 256 --check orangepi5plus-archlinuxarm.img.sha256)
sudo dd if=dist/orangepi5plus-archlinuxarm.img of=/dev/rdiskN bs=4m
sync
```

### Balena Etcher or Raspberry Pi Imager

Choose the raw `dist/orangepi5plus-archlinuxarm.img` as a custom image, select the microSD card, and flash it. Verify the checksum file before flashing. Raspberry Pi Imager settings intended for Raspberry Pi OS do not configure this image.

## First boot

Insert the card and power on the board. The root partition and ext4 filesystem expand to fill the card during first boot. Expansion is idempotent and a failure does not block login.

The default hostname is `orangepi-agent`.

| Account | Initial password | Access |
|---|---|---|
| `alarm` | `alarm` | Local login, SSH, and password-authenticated `sudo` |
| `root` | `root` | Local login only; root SSH login is disabled |

Both passwords must be changed on first use. The image contains no persistent machine ID, SSH host keys, Wi-Fi credentials, NetworkManager connection profiles, or random seed. Machine identity, SSH host keys, and the pacman keyring are generated on the board.

## Networking and Wi-Fi

NetworkManager manages Ethernet and Wi-Fi. `wpa_supplicant` is the active Wi-Fi backend; iwd does not manage `wlan0`. Wired interfaces request DHCP automatically.

The following USB adapter path has been confirmed on physical hardware:

| Item | Value |
|---|---|
| Adapter | TP-Link TL-WN725N |
| USB ID | `0bda:8179` |
| Chipset | Realtek RTL8188EUS |
| Driver | In-kernel `rtl8xxxu` |
| Firmware | `/usr/lib/firmware/rtlwifi/rtl8188eufw.bin` |

The build installs `rtl8xxxu` and its dependencies beneath `/usr/lib/modules/6.18.50-orangepi5plus/`, runs `depmod`, retains normal USB hotplug aliases, and explicitly loads the module through `/etc/modules-load.d/rtl8xxxu.conf` when the adapter is already inserted at boot.

No wireless network or password is embedded. Connect after logging in:

```sh
nmcli device wifi list
sudo nmcli device wifi connect "SSID" password "PASSWORD"
```

NetworkManager saves the new connection on the running installation. To keep a password out of shell history, use the interactive form instead:

```sh
sudo nmcli --ask device wifi connect "SSID"
```

Useful diagnostics:

```sh
lsusb
rfkill
ip link show wlan0
journalctl -b -u NetworkManager -u wpa_supplicant
dmesg | grep -Ei 'rtl8|firmware|wlan'
```

## Build from source

Build on Linux with Docker Engine, Docker Buildx, and AArch64 container execution available. The build container is pinned to Debian Bookworm packages from the snapshot recorded in the `Dockerfile`. The first fetch needs network access; later builds reuse the verified files in `downloads/`.

Reserve approximately 20 GB of Linux-backed Docker storage for one clean build. Keep the repository and Docker volume on Linux storage when possible; this avoids slow metadata operations and preserves the ownership and filesystem attributes used while assembling the root filesystem. Set `JOBS` to limit parallel compilation if the host has limited memory.

Run the normal build from the repository root:

```sh
./build.sh fetch
./build.sh build
./build.sh inspect
```

The build uses the persistent Docker volume `orangepi5plus-arch-build` for sources and intermediate output. A later `./build.sh build` reuses completed component builds when their pinned inputs and configuration hashes still match. For example, limit the kernel build to four jobs with:

```sh
JOBS=4 ./build.sh build
```

The final raw image is suitable for direct SD-card flashing. The compressed image is produced with pinned single-threaded Zstandard compression. Check `dist/image-measurements.txt` for the current raw apparent size, sparse allocation, compressed size, rootfs payload, and filesystem free space.

Artifacts are published atomically beneath `dist/`:

- `orangepi5plus-archlinuxarm.img`
- `orangepi5plus-archlinuxarm.img.zst`
- SHA-256 checksum files for both images
- `build-manifest.txt`, `image-measurements.txt`, and `inspection.txt`
- `u-boot-rockchip.bin`, `u-boot.itb`, logs, source metadata, and firmware license information

`downloads/` is the content-verified source and package bundle used for offline reruns. Every build verifies pinned source hashes, the Arch Linux ARM rootfs signature, package signatures, signing-key fingerprints, and the package lock before compiling or assembling the image. A failed verification stops the build; it never silently refreshes an input.

### Update the package lock

Normal builds never resolve against moving repositories. Refresh the userspace baseline only as an intentional maintenance operation. This replaces the package lock and verified package bundle, so review the resulting changes before building a release image:

```sh
./build.sh refresh-packages
./build.sh build
./build.sh inspect
```

`refresh-packages` resolves one coherent Arch Linux ARM package set, downloads packages and detached signatures, records signer fingerprints, preserves the repository databases, and replaces `config/packages.lock`.

After changing `config/linux.fragment`, `config/packages.txt`, the rootfs overlay, or the pinned inputs, run `./build.sh build` and then `./build.sh inspect` again. A kernel-fragment change rebuilds Linux and the custom kernel package; package, overlay, and image-layout changes reuse the boot components and rebuild the affected assembly stages.

For the NVMe-root variant, use the targeted kernel rebuild. It reuses the existing SD image and boot chain, installs the rebuilt kernel package into the image, regenerates the compressed artifact and checksums, and removes its temporary Docker volume when finished:

```sh
./build.sh rebuild-kernel-nvme
```

This target keeps the kernel at `6.18.50` and makes the Rockchip PCIe/NVMe host, PCIe3 PHY, NVMe core, and NVMe block driver built in so the root filesystem can be mounted before modules are available.

### Verify reproducibility

```sh
./build.sh verify-reproducible
```

This performs two independent clean builds, releasing the first build workspace before starting the second, and compares both the raw and compressed image hashes. Separate manifests, logs, and inspection results are retained in `dist/`.

This optional check was outside the scope of the current artifact build, so the current image has no two-build byte-reproducibility claim.

To remove generated build state and `dist/` while retaining verified downloads:

```sh
./build.sh clean
```

## Current image measurements

These values come from the current `dist/image-measurements.txt`:

| Measurement | Bytes | Approximate size |
|---|---:|---:|
| Raw apparent size | 3,910,139,904 | 3.64 GiB |
| Raw sparse allocation | 2,839,937,024 | 2.64 GiB |
| Compressed image | 814,714,796 | 777 MiB |
| Rootfs payload before ext4 | 2,842,288,148 | 2.65 GiB |
| Ext4 used before expansion | 2,877,235,200 | 2.68 GiB |
| Ext4 usable free space | 820,465,664 | 782 MiB |
| Root partition | 3,892,314,112 | 3.62 GiB |

The builder calculates image capacity from the installed rootfs and adds at least 768 MiB or 25% headroom, whichever is larger. Check `dist/image-measurements.txt` after every rebuild; it is authoritative for the artifact being flashed.

## Boot layout

The image uses a GPT with one ext4 root partition. `/boot` lives on that filesystem.

| Region | Location |
|---|---:|
| Combined Rockchip/U-Boot image | 32 KiB, LBA 64 |
| U-Boot FIT payload | 8 MiB, LBA 16384 |
| Root partition | 16 MiB, LBA 32768 |

The raw boot areas and partition start are checked for overlap during assembly. Inspection also verifies GPT integrity, filesystem integrity, bootloader bytes, extlinux paths, DTB compatibility, kernel configuration, module aliases, firmware, installed packages, enabled services, and absence of generated secrets.

## UART and recovery

Use a **3.3 V UART adapter** at **1500000 baud, 8N1**. Connect ground, receive, and transmit only. Do not connect the adapter's power pin.

Capture output from power-on and identify the last stage reached:

| Last visible stage | Area to inspect |
|---|---|
| DDR or SPL | SD detection, DDR binary, raw U-Boot placement |
| TF-A or BL31 | Trusted-firmware handoff |
| U-Boot prompt or banner | Active boot source, storage, extlinux files |
| `Starting kernel` or later | Kernel, DTB, root PARTUUID, drivers, userspace |

An existing SPI or eMMC bootloader may take priority before the SD card. Compare its U-Boot version and timestamp with `dist/build-manifest.txt`. Diagnose or temporarily select SD where the board supports it; this project does not erase or rewrite SPI or eMMC. Disconnect power before removing removable eMMC hardware.

If U-Boot starts but Linux does not, interrupt the countdown and inspect the SD device and boot files:

```text
mmc list
part list mmc 1
ext4ls mmc 1:1 /boot/extlinux
```

If Linux cannot mount root, compare the PARTUUID in `/boot/extlinux/extlinux.conf` and `/etc/fstab` with `sgdisk --info=1` on another Linux system. Both files can be repaired by mounting the SD root partition offline. Reflash when the GPT, filesystem, or bootloader region fails `./build.sh inspect`.

## Hardware validation and limitations

The TL-WN725N `0bda:8179` path with `rtl8xxxu`, its firmware, NetworkManager, and `wpa_supplicant` is confirmed working on physical hardware. Every newly generated release image still requires a cold-boot regression check for SD-root boot, detected RAM, both Ethernet ports, SSH, HDMI, UART, Panthor, first-boot expansion, and a second reboot before that artifact is described as fully hardware-verified.

Mainline support for graphics, multimedia codecs, cameras, and the NPU remains less complete than the vendor BSP. The build intentionally keeps the upstream stack and does not claim complete multimedia or accelerator support.
