#!/usr/bin/env bash
# Arch Linux UEFI installer — HP Laptop 15-dw3xxx
# Manual GPT partitioning; formats ONLY the three explicitly validated partitions.
# Layout: EFI (1 GiB, FAT32) + swap (8 GiB) + root (remaining, ext4).
# Boot: GRUB; kernel: linux-zen; desktop: stock GNOME / Wayland.
# Intel iGPU support; no proprietary NVIDIA driver installed.
# WARNING: Formatting the chosen partitions destroys their existing data.

set -Eeuo pipefail

DISK='/dev/nvme0n1'
EFI="${DISK}p1"
SWAP="${DISK}p2"
ROOT="${DISK}p3"
TARGET='/mnt'
NEW_HOSTNAME='hp-arch'
TIMEZONE='Asia/Tashkent'
TARGET_LANG='en_US.UTF-8'

EFI_GUID='c12a7328-f81f-11d2-ba4b-00a0c93ec93b'
SWAP_GUID='0657fd6d-a4ab-43c4-84e5-0933c84b4f4f'
LINUX_FS_GUID='0fc63daf-8483-4772-8e79-3d69d8477de4'
LINUX_X64_ROOT_GUID='4f68bce3-e8cd-4db1-96e7-fbcaf984b709'

on_error() {
    local code=$?
    printf '\nERROR: Installation stopped (exit code %s, line %s).\n' "$code" "$1" >&2
    printf 'Inspect the preceding error. Existing mounts are left intact for diagnosis.\n' >&2
    exit "$code"
}
trap 'on_error "$LINENO"' ERR

fail() {
    printf '\nERROR: %s\n' "$*" >&2
    exit 1
}

require_command() {
    command -v "$1" >/dev/null 2>&1 || fail "Required tool not found: $1"
}

ensure_target_unmounted() {
    # A mounted target disk (including any child partition) must never be formatted.
    if lsblk -nrpo MOUNTPOINTS "$DISK" | grep -q '[^[:space:]]'; then
        fail "A filesystem on $DISK is mounted. Unmount it before continuing."
    fi
    if findmnt -rn -o TARGET | grep -Eq '^/mnt(/|$)'; then
        fail "$TARGET already has mounted filesystems. Unmount them before continuing."
    fi
    # /proc/swaps is stable across util-linux versions, unlike swapon CLI options.
    local swap_path resolved
    while IFS=$' \t' read -r swap_path _; do
        [[ "$swap_path" == Filename || -z "$swap_path" ]] && continue
        resolved=$(readlink -f -- "$swap_path") || fail "Cannot resolve active swap: $swap_path"
        case "$resolved" in
            "$DISK"|"$DISK"p[0-9]*)
                fail "Target disk contains active swap: $resolved" ;;
        esac
    done < /proc/swaps
}

check_partition() {
    local path="$1" role="$2" expected_type="$3" actual_type parent
    [[ -b "$path" ]] || fail "$role partition missing: $path"
    [[ "$(lsblk -dnro TYPE "$path")" == part ]] || fail "$role is not a partition: $path"
    parent=$(lsblk -dnro PKNAME "$path")
    [[ "$parent" == "${DISK##*/}" ]] || fail "$path does not belong to $DISK"
    actual_type=$(lsblk -dnro PARTTYPE "$path")
    actual_type=${actual_type,,}
    if [[ "$role" == ROOT ]]; then
        [[ "$actual_type" == "$LINUX_FS_GUID" || "$actual_type" == "$LINUX_X64_ROOT_GUID" ]] \
            || fail "$path has GPT type '$actual_type'; choose Linux filesystem/root x86-64 in cfdisk"
    else
        [[ "$actual_type" == "$expected_type" ]] \
            || fail "$path has GPT type '$actual_type'; expected '$expected_type' for $role"
    fi
}

bytes_at_least() {
    local size
    size=$(blockdev --getsize64 "$1")
    (( size >= "$2" )) || fail "$3 partition $1 is too small ($size bytes)"
}

[[ $EUID -eq 0 ]] || fail 'Run as root from the official Arch Linux Live ISO.'
[[ -d /sys/firmware/efi ]] || fail 'Live ISO was not booted in UEFI mode.'
[[ -b "$DISK" ]] || fail "Disk not found: $DISK"
[[ "$(lsblk -dnro TYPE "$DISK")" == disk ]] || fail "$DISK is not a disk"

for utility in lsblk findmnt readlink blockdev cfdisk partprobe udevadm \
               mkfs.fat mkswap mkfs.ext4 mount umount swapon swapoff \
               pacman pacstrap genfstab arch-chroot curl timedatectl \
               sed awk grep tee; do
    require_command "$utility"
done

printf '\n=== ARCH LINUX: MANUAL PARTITION INSTALL ===\n'
printf 'Target disk: %s\n' "$DISK"
lsblk -o NAME,SIZE,TYPE,FSTYPE,MOUNTPOINTS,MODEL "$DISK"
printf '\nThis script NEVER calls wipefs or sfdisk.\n'
printf 'It WILL format EFI=%s, SWAP=%s, ROOT=%s after explicit confirmation.\n' "$EFI" "$SWAP" "$ROOT"

ensure_target_unmounted

printf '\n=== MANUAL GPT PARTITIONING ===\n'
printf 'Use cfdisk to create these partitions, in this order:\n'
printf '  p1: 1 GiB     Type: EFI System\n'
printf '  p2: 8 GiB     Type: Linux swap\n'
printf '  p3: remaining Type: Linux filesystem\n'
printf 'In cfdisk choose GPT if asked, then Write -> yes -> Quit.\n'
printf 'Do not create extra partitions before p1/p2/p3.\n'
read -r -p 'Open cfdisk now? [y/N]: ' OPEN_CFDISK
if [[ "$OPEN_CFDISK" =~ ^[Yy]$ ]]; then
    cfdisk "$DISK"
fi

# Re-read the on-disk partition table; give udev a chance to expose devices.
partprobe "$DISK"
udevadm settle
for part in "$EFI" "$SWAP" "$ROOT"; do
    for ((try=0; try<10; try++)); do
        [[ -b "$part" ]] && break
        sleep 1
    done
    [[ -b "$part" ]] || fail "Partition not visible: $part. Check the partition table."
done

[[ "$(lsblk -dnro PTTYPE "$DISK")" == gpt ]] || fail 'Expected a GPT partition table.'
check_partition "$EFI" EFI "$EFI_GUID"
check_partition "$SWAP" SWAP "$SWAP_GUID"
check_partition "$ROOT" ROOT "$LINUX_FS_GUID"
bytes_at_least "$EFI" 536870912 EFI          # >= 512 MiB
bytes_at_least "$SWAP" 7516192768 SWAP        # >= 7 GiB
bytes_at_least "$ROOT" 34359738368 ROOT       # >= 32 GiB
ensure_target_unmounted

printf '\nValidated partition table:\n'
lsblk -o NAME,SIZE,TYPE,PARTTYPE,FSTYPE,MOUNTPOINTS "$DISK"

printf '\nChecking internet / package repositories...\n'
curl -fsS --connect-timeout 10 --max-time 25 https://archlinux.org/ >/dev/null \
    || fail 'Network check failed. Connect Live ISO to the internet first.'
timedatectl set-ntp true || printf 'Warning: unable to enable NTP. Check the clock.\n' >&2

# Sync package databases on the disposable Live ISO BEFORE touching partitions.
pacman -Sy --noconfirm

CPU_VENDOR=$(awk -F ': *' '/^vendor_id/ { print $2; exit }' /proc/cpuinfo)
case "$CPU_VENDOR" in
    GenuineIntel) MICROCODE='intel-ucode' ;;
    AuthenticAMD) MICROCODE='amd-ucode' ;;
    *) fail "Unknown CPU vendor: $CPU_VENDOR" ;;
esac
printf 'CPU vendor: %s; microcode: %s\n' "$CPU_VENDOR" "$MICROCODE"

BASE_PACKAGES=(
    base base-devel linux-zen linux-zen-headers linux-firmware
    mkinitcpio "$MICROCODE" grub efibootmgr networkmanager wpa_supplicant
    sudo git curl wget vim nano man-db man-pages
    dosfstools mtools
)
DESKTOP_PACKAGES=(
    gdm gnome-tweaks firefox
    pipewire pipewire-audio pipewire-alsa pipewire-pulse
    wireplumber pavucontrol
    mesa vulkan-intel intel-media-driver libva-utils
    sof-firmware
    noto-fonts noto-fonts-cjk noto-fonts-emoji ttf-dejavu
    bluez bluez-utils power-profiles-daemon fwupd
    gvfs gvfs-mtp xdg-user-dirs xdg-utils
    android-tools ntfs-3g 7zip jq htop fastfetch
)

# Fail before formatting if a package disappeared or mirrors/repository indexes are wrong.
for package in "${BASE_PACKAGES[@]}" "${DESKTOP_PACKAGES[@]}"; do
    pacman -Si "$package" >/dev/null 2>&1 || fail "Package unavailable: $package"
done
pacman -Sgq gnome >/dev/null || fail 'The GNOME package group is unavailable.'

read -r -p 'New Linux username (lowercase): ' USERNAME
[[ "$USERNAME" =~ ^[a-z_][a-z0-9_-]*$ ]] || fail 'Invalid username.'
[[ "$USERNAME" != root ]] || fail 'Use a non-root username.'

printf '\n=== LAST CONFIRMATION: FORMATTING ===\n'
printf 'SSD: %s\n' "$DISK"
printf 'EFI : %s -> FAT32 -> /boot\n' "$EFI"
printf 'SWAP: %s -> Linux swap\n' "$SWAP"
printf 'ROOT: %s -> ext4 -> /\n' "$ROOT"
printf 'ALL EXISTING DATA ON THESE PARTITIONS WILL BE LOST.\n'
read -r -p "Type exactly 'FORMAT $DISK' to continue: " CONFIRM
[[ "$CONFIRM" == "FORMAT $DISK" ]] || { printf 'Cancelled; nothing formatted by this script.\n'; exit 0; }

# Check once more, immediately before destructive operations.
ensure_target_unmounted
printf '\nFormatting validated partitions...\n'
mkfs.fat -F 32 "$EFI"
mkswap "$SWAP"
mkfs.ext4 -F "$ROOT"

mount "$ROOT" "$TARGET"
mkdir -p "$TARGET/boot"
mount "$EFI" "$TARGET/boot"
swapon "$SWAP"

printf '\nInstalling Arch base + linux-zen...\n'
pacstrap -K "$TARGET" "${BASE_PACKAGES[@]}"

genfstab -U "$TARGET" > "$TARGET/etc/fstab"
printf '\nGenerated fstab:\n'
cat "$TARGET/etc/fstab"
# Ensure the expected root, EFI, and swap records were written.
[[ $(grep -Ec '[[:space:]]/[[:space:]]+ext4[[:space:]]' "$TARGET/etc/fstab") -eq 1 ]] \
    || fail 'Expected exactly one root ext4 entry in fstab.'
[[ $(grep -Ec '[[:space:]]/boot[[:space:]]+vfat[[:space:]]' "$TARGET/etc/fstab") -eq 1 ]] \
    || fail 'Expected exactly one EFI /boot entry in fstab.'
[[ $(grep -Ec '[[:space:]]none[[:space:]]+swap[[:space:]]' "$TARGET/etc/fstab") -eq 1 ]] \
    || fail 'Expected exactly one swap entry in fstab.'

printf '\nConfiguring locale, timezone, users, and services...\n'
arch-chroot "$TARGET" ln -sf "/usr/share/zoneinfo/$TIMEZONE" /etc/localtime
arch-chroot "$TARGET" hwclock --systohc
sed -i \
    -e 's/^#en_US.UTF-8 UTF-8/en_US.UTF-8 UTF-8/' \
    -e 's/^#ru_RU.UTF-8 UTF-8/ru_RU.UTF-8 UTF-8/' \
    -e 's/^#uz_UZ.UTF-8 UTF-8/uz_UZ.UTF-8 UTF-8/' \
    "$TARGET/etc/locale.gen"
arch-chroot "$TARGET" locale-gen
printf 'LANG=%s\n' "$TARGET_LANG" > "$TARGET/etc/locale.conf"
printf 'KEYMAP=us\n' > "$TARGET/etc/vconsole.conf"
printf '%s\n' "$NEW_HOSTNAME" > "$TARGET/etc/hostname"
cat > "$TARGET/etc/hosts" <<EOF
127.0.0.1 localhost
::1 localhost
127.0.1.1 ${NEW_HOSTNAME}.localdomain ${NEW_HOSTNAME}
EOF

sed -i \
    -e 's/^#Color/Color/' \
    -e 's/^#ParallelDownloads = 5/ParallelDownloads = 5/' \
    "$TARGET/etc/pacman.conf"

arch-chroot "$TARGET" useradd -m -G wheel -s /bin/bash "$USERNAME"
mkdir -p "$TARGET/etc/sudoers.d"
printf '%%wheel ALL=(ALL:ALL) ALL\n' > "$TARGET/etc/sudoers.d/10-wheel"
chmod 0440 "$TARGET/etc/sudoers.d/10-wheel"
arch-chroot "$TARGET" visudo -c

printf '\nSet the root password for the installed Arch system:\n'
arch-chroot "$TARGET" passwd root
printf '\nSet the password for %s:\n' "$USERNAME"
arch-chroot "$TARGET" passwd "$USERNAME"

printf '\nInstalling stock GNOME (the full official GNOME group)...\n'
arch-chroot "$TARGET" pacman -S --needed --noconfirm gnome "${DESKTOP_PACKAGES[@]}"

printf '\nGenerating initramfs and installing GRUB/UEFI...\n'
arch-chroot "$TARGET" mkinitcpio -P
arch-chroot "$TARGET" grub-install \
    --target=x86_64-efi --efi-directory=/boot \
    --bootloader-id=ArchLinux --recheck
arch-chroot "$TARGET" grub-mkconfig -o /boot/grub/grub.cfg

for service in NetworkManager.service gdm.service bluetooth.service \
               power-profiles-daemon.service fstrim.timer; do
    arch-chroot "$TARGET" systemctl enable "$service"
done

printf '\nValidating installation...\n'
arch-chroot "$TARGET" pacman -Q linux-zen linux-zen-headers grub gnome-shell gdm
[[ -s "$TARGET/boot/vmlinuz-linux-zen" ]] || fail 'Kernel is missing from /boot.'
[[ -s "$TARGET/boot/initramfs-linux-zen.img" ]] || fail 'Initramfs is missing from /boot.'
[[ -s "$TARGET/boot/grub/grub.cfg" ]] || fail 'GRUB config is missing.'
findmnt --verify --tab-file "$TARGET/etc/fstab"

printf '\nFinal partition layout:\n'
lsblk -o NAME,SIZE,FSTYPE,MOUNTPOINTS "$DISK"
sync
umount -R "$TARGET"
swapoff "$SWAP"

printf '\n=== INSTALLATION COMPLETED SUCCESSFULLY ===\n'
printf 'Host: %s | User: %s | Kernel: linux-zen | GNOME / Wayland\n' "$NEW_HOSTNAME" "$USERNAME"
printf 'No NVIDIA proprietary driver was installed.\n'
printf 'Remove your installation USB before the first normal boot.\n'
read -r -p 'Reboot now? [y/N]: ' REBOOT
if [[ "$REBOOT" =~ ^[Yy]$ ]]; then
    reboot
else
    printf 'Done. Reboot manually when ready.\n'
fi
