#!/usr/bin/env bash
# =============================================================================
#  arch-install.sh  —  Minimal Arch Linux Dual-Boot Installer
#  Usage:  curl -L <url> | bash
#          or: bash arch-install.sh
# =============================================================================

set -euo pipefail

# ── colours ──────────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'

info()    { echo -e "${CYAN}[INFO]${NC}  $*"; }
success() { echo -e "${GREEN}[OK]${NC}    $*"; }
warn()    { echo -e "${YELLOW}[WARN]${NC}  $*"; }
die()     { echo -e "${RED}[ERR]${NC}   $*" >&2; exit 1; }

# ── sanity checks ────────────────────────────────────────────────────────────
[[ $EUID -eq 0 ]] || die "Run as root (or via sudo)."
command -v pacstrap &>/dev/null || die "This script must run from an Arch ISO live environment."

clear
echo -e "${BOLD}============================================${NC}"
echo -e "${BOLD}   Arch Linux Minimal Dual-Boot Installer  ${NC}"
echo -e "${BOLD}============================================${NC}"
echo ""

# ── detect live WiFi profiles to transplant later ────────────────────────────
# iwd (iwctl) stores WPA profiles in /var/lib/iwd/*.psk
# NetworkManager stores them in /etc/NetworkManager/system-connections/
IWD_SRC="/var/lib/iwd"
NM_SRC="/etc/NetworkManager/system-connections"
WIFI_IWD=false
WIFI_NM=false

if compgen -G "${IWD_SRC}/*.psk" &>/dev/null || \
   compgen -G "${IWD_SRC}/*.8021x" &>/dev/null; then
  WIFI_IWD=true
  info "Detected iwd (iwctl) WiFi profiles — will copy to installed system."
fi

if compgen -G "${NM_SRC}/*.nmconnection" &>/dev/null 2>/dev/null; then
  WIFI_NM=true
  info "Detected NetworkManager WiFi profiles — will copy to installed system."
fi

if [[ "$WIFI_IWD" == false && "$WIFI_NM" == false ]]; then
  warn "No saved WiFi profiles found in the live environment."
  warn "Connect via 'iwctl' first, then re-run — or reconnect after first boot with 'nmtui'."
fi

# ── user details ─────────────────────────────────────────────────────────────
echo ""
read -rp "$(echo -e "${YELLOW}Enter your timezone${NC} [e.g. Asia/Singapore]: ")" TIMEZONE
TIMEZONE=${TIMEZONE:-Asia/Singapore}

read -rp "$(echo -e "${YELLOW}Enter hostname for the new system${NC}: ")" HOSTNAME
HOSTNAME=${HOSTNAME:-archlinux}

read -rp "$(echo -e "${YELLOW}Enter username to create${NC}: ")" USERNAME
USERNAME=${USERNAME:-user}

while true; do
  read -rsp "$(echo -e "${YELLOW}Enter password for ${USERNAME} (and root)${NC}: ")" PASSWORD; echo
  read -rsp "$(echo -e "${YELLOW}Confirm password${NC}: ")" PASSWORD2; echo
  [[ "$PASSWORD" == "$PASSWORD2" ]] && break
  warn "Passwords do not match, try again."
done

# ── drive selection ───────────────────────────────────────────────────────────
echo ""
info "Detected block devices:"
echo ""
lsblk -d -o NAME,SIZE,MODEL,TYPE | grep -v "^loop" | grep "disk"
echo ""

DRIVES=()
while IFS= read -r line; do
  DRIVES+=("$line")
done < <(lsblk -d -n -o NAME | grep -v "^loop")

[[ ${#DRIVES[@]} -gt 0 ]] || die "No drives detected."

echo -e "${YELLOW}Select the drive to install Arch Linux on:${NC}"
for i in "${!DRIVES[@]}"; do
  SIZE=$(lsblk -d -n -o SIZE "/dev/${DRIVES[$i]}")
  MODEL=$(lsblk -d -n -o MODEL "/dev/${DRIVES[$i]}" 2>/dev/null || echo "")
  echo -e "  ${BOLD}$((i+1))${NC}) /dev/${DRIVES[$i]}  ${SIZE}  ${MODEL}"
done
echo ""

while true; do
  read -rp "Enter number [1-${#DRIVES[@]}]: " SEL
  [[ "$SEL" =~ ^[0-9]+$ ]] && (( SEL >= 1 && SEL <= ${#DRIVES[@]} )) && break
  warn "Invalid selection."
done

TARGET_DISK="/dev/${DRIVES[$((SEL-1))]}"
info "Selected: ${TARGET_DISK}"

# ── partition strategy ────────────────────────────────────────────────────────
echo ""
echo -e "${YELLOW}Partition strategy:${NC}"
echo -e "  ${BOLD}1)${NC} Use free/unallocated space on ${TARGET_DISK}  (dual-boot safe)"
echo -e "  ${BOLD}2)${NC} Wipe entire disk and use it fully  ${RED}(DESTROYS ALL DATA)${NC}"
echo ""

while true; do
  read -rp "Choose [1/2]: " PART_MODE
  [[ "$PART_MODE" == "1" || "$PART_MODE" == "2" ]] && break
  warn "Enter 1 or 2."
done

# ── helper: locate EFI partition ─────────────────────────────────────────────
find_efi_partition() {
  lsblk -ln -o NAME,PARTTYPE "${TARGET_DISK}" 2>/dev/null \
    | awk 'tolower($2) ~ /c12a7328/' \
    | head -1 | awk '{print "/dev/"$1}'
}

# ── WHOLE DISK mode ───────────────────────────────────────────────────────────
if [[ "$PART_MODE" == "2" ]]; then
  echo ""
  warn "This will ERASE ${TARGET_DISK} completely, including any Windows install!"
  read -rp "$(echo -e "${RED}Type YES to confirm${NC}: ")" CONFIRM
  [[ "$CONFIRM" == "YES" ]] || die "Aborted."

  info "Wiping ${TARGET_DISK} and creating GPT layout..."
  sgdisk --zap-all "${TARGET_DISK}"
  sgdisk -n 1:0:+512M -t 1:EF00 -c 1:"EFI"     "${TARGET_DISK}"
  sgdisk -n 2:0:0     -t 2:8300 -c 2:"ArchRoot" "${TARGET_DISK}"
  partprobe "${TARGET_DISK}"
  sleep 1

  if [[ "${TARGET_DISK}" =~ nvme ]]; then
    EFI_PART="${TARGET_DISK}p1"; ROOT_PART="${TARGET_DISK}p2"
  else
    EFI_PART="${TARGET_DISK}1";  ROOT_PART="${TARGET_DISK}2"
  fi

  info "Formatting EFI (FAT32)...";  mkfs.fat -F32 "${EFI_PART}"
  info "Formatting root (ext4)...";  mkfs.ext4 -F   "${ROOT_PART}"

# ── FREE SPACE mode ───────────────────────────────────────────────────────────
else
  echo ""
  info "Current partition layout of ${TARGET_DISK}:"
  parted "${TARGET_DISK}" print free 2>/dev/null || fdisk -l "${TARGET_DISK}"
  echo ""

  # Collect all unallocated free regions (start, end, size) in MiB
  FREE_REGIONS=()
  while IFS= read -r line; do
    FREE_REGIONS+=("$line")
  done < <(parted -s "${TARGET_DISK}" unit MiB print free \
    | awk '/Free Space/ {
        # strip "MiB" suffix from each field
        gsub(/MiB/,"",$1); gsub(/MiB/,"",$2); gsub(/MiB/,"",$3)
        printf "%s:%s:%s\n", $1, $2, $3
      }')

  [[ ${#FREE_REGIONS[@]} -gt 0 ]] \
    || die "No unallocated free space found on ${TARGET_DISK}. Shrink a partition in Windows first."

  # Show free regions for selection
  echo -e "${YELLOW}Unallocated free regions on ${TARGET_DISK}:${NC}"
  for i in "${!FREE_REGIONS[@]}"; do
    IFS=: read -r FS FE FSIZ <<< "${FREE_REGIONS[$i]}"
    SIZE_GIB=$(awk "BEGIN {printf \"%.1f\", ${FSIZ}/1024}")
    echo -e "  ${BOLD}$((i+1))${NC}) Start: ${FS} MiB  End: ${FE} MiB  Size: ${SIZE_GIB} GiB"
  done
  echo ""

  while true; do
    read -rp "Select region [1-${#FREE_REGIONS[@]}]: " RSEL
    [[ "$RSEL" =~ ^[0-9]+$ ]] && (( RSEL >= 1 && RSEL <= ${#FREE_REGIONS[@]} )) && break
    warn "Invalid selection."
  done

  IFS=: read -r FREE_START FREE_END FREE_SIZ <<< "${FREE_REGIONS[$((RSEL-1))]}"
  FREE_GIB=$(awk "BEGIN {printf \"%.1f\", ${FREE_SIZ}/1024}")

  echo ""
  echo -e "${YELLOW}How much of this region to use?${NC}"
  echo -e "  ${BOLD}1)${NC} Use the entire region (${FREE_GIB} GiB)"
  echo -e "  ${BOLD}2)${NC} Specify a size in GiB"
  echo ""

  while true; do
    read -rp "Choose [1/2]: " SIZE_MODE
    [[ "$SIZE_MODE" == "1" || "$SIZE_MODE" == "2" ]] && break
    warn "Enter 1 or 2."
  done

  if [[ "$SIZE_MODE" == "1" ]]; then
    ROOT_START_MIB="${FREE_START}"
    ROOT_END_MIB="${FREE_END}"
    info "Using entire free region: ${FREE_START} MiB → ${FREE_END} MiB (${FREE_GIB} GiB)"
  else
    while true; do
      read -rp "$(echo -e "${YELLOW}Size in GiB (max ${FREE_GIB})${NC}: ")" ROOT_GIB
      [[ "$ROOT_GIB" =~ ^[0-9]+$ ]] || { warn "Enter a whole number."; continue; }
      MAX_GIB=$(awk "BEGIN {printf \"%d\", ${FREE_SIZ}/1024}")
      (( ROOT_GIB <= MAX_GIB && ROOT_GIB > 0 )) && break
      warn "Must be between 1 and ${MAX_GIB} GiB."
    done
    ROOT_START_MIB="${FREE_START}"
    ROOT_END_MIB=$(( FREE_START + ROOT_GIB * 1024 ))
    info "Creating ${ROOT_GIB} GiB partition starting at ${ROOT_START_MIB} MiB"
  fi

  parted -s "${TARGET_DISK}" unit MiB \
    mkpart primary ext4 "${ROOT_START_MIB}MiB" "${ROOT_END_MIB}MiB"
  partprobe "${TARGET_DISK}"
  sleep 1

  # The new partition is the last one listed on the disk
  ROOT_PART=$(lsblk -ln -o NAME "${TARGET_DISK}" \
    | grep -v "$(basename "${TARGET_DISK}")$" | tail -1)
  ROOT_PART="/dev/${ROOT_PART}"

  info "Formatting ${ROOT_PART} as ext4..."
  mkfs.ext4 -F "${ROOT_PART}"

  EFI_PART=$(find_efi_partition)
  [[ -n "$EFI_PART" ]] || die "No EFI partition found on ${TARGET_DISK}. UEFI+GPT required."
  info "Using existing EFI partition: ${EFI_PART}"
fi

# ── mount ─────────────────────────────────────────────────────────────────────
info "Mounting filesystems..."
mount "${ROOT_PART}" /mnt
mkdir -p /mnt/boot/efi
mount "${EFI_PART}" /mnt/boot/efi

# ── base install ──────────────────────────────────────────────────────────────
info "Installing base system (this takes a few minutes)..."
pacstrap /mnt \
  base base-devel linux linux-firmware \
  networkmanager grub efibootmgr os-prober \
  nano sudo

# ── fstab ─────────────────────────────────────────────────────────────────────
info "Generating fstab..."
genfstab -U /mnt >> /mnt/etc/fstab

# ── transplant WiFi profiles ──────────────────────────────────────────────────
info "Transplanting WiFi profiles into installed system..."

# 1) Copy raw iwd profiles (useful if user installs iwd later)
if [[ "$WIFI_IWD" == true ]]; then
  mkdir -p /mnt/var/lib/iwd
  cp -v "${IWD_SRC}"/*.psk   /mnt/var/lib/iwd/ 2>/dev/null || true
  cp -v "${IWD_SRC}"/*.8021x /mnt/var/lib/iwd/ 2>/dev/null || true
  chmod 600 /mnt/var/lib/iwd/* 2>/dev/null || true
  success "iwd profiles copied → /var/lib/iwd/"
fi

# 2) Copy existing NM profiles directly
if [[ "$WIFI_NM" == true ]]; then
  mkdir -p /mnt/etc/NetworkManager/system-connections
  cp -v "${NM_SRC}"/*.nmconnection \
        /mnt/etc/NetworkManager/system-connections/ 2>/dev/null || true
  chmod 600 /mnt/etc/NetworkManager/system-connections/*.nmconnection 2>/dev/null || true
  success "NetworkManager profiles copied → /etc/NetworkManager/system-connections/"
fi

# 3) Convert iwd .psk files → NM keyfiles so NetworkManager can use them
#    without needing iwd installed at all.
if [[ "$WIFI_IWD" == true ]]; then
  mkdir -p /mnt/etc/NetworkManager/system-connections
  for PSK_FILE in "${IWD_SRC}"/*.psk; do
    [[ -f "$PSK_FILE" ]] || continue
    SSID=$(basename "$PSK_FILE" .psk)
    # iwd can store either a plain Passphrase= or a hex PreSharedKey=
    PSK_PLAIN=$(grep -Po '(?<=Passphrase=).+' "$PSK_FILE" 2>/dev/null || true)
    PSK_HEX=$(grep -Po '(?<=PreSharedKey=)[0-9a-fA-F]+' "$PSK_FILE" 2>/dev/null || true)

    if [[ -n "$PSK_PLAIN" ]]; then
      PSK_LINE="psk=${PSK_PLAIN}"
    elif [[ -n "$PSK_HEX" ]]; then
      PSK_LINE="psk=${PSK_HEX}"
    else
      warn "Cannot extract key for SSID '${SSID}' — skipping NM keyfile."
      continue
    fi

    NM_FILE="/mnt/etc/NetworkManager/system-connections/${SSID}.nmconnection"
    # Don't overwrite if already copied from NM_SRC above
    [[ -f "$NM_FILE" ]] && continue

    cat > "$NM_FILE" <<EOF
[connection]
id=${SSID}
type=wifi
autoconnect=true

[wifi]
mode=infrastructure
ssid=${SSID}

[wifi-security]
auth-alg=open
key-mgmt=wpa-psk
${PSK_LINE}

[ipv4]
method=auto

[ipv6]
addr-gen-mode=stable-privacy
method=auto
EOF
    chmod 600 "$NM_FILE"
    success "NM keyfile created for SSID: ${SSID}"
  done
fi

# ── chroot configuration ──────────────────────────────────────────────────────
info "Configuring system inside chroot..."

arch-chroot /mnt /bin/bash <<CHROOT
set -euo pipefail

# Timezone
ln -sf "/usr/share/zoneinfo/${TIMEZONE}" /etc/localtime
hwclock --systohc

# Locale
sed -i 's/#en_US.UTF-8/en_US.UTF-8/' /etc/locale.gen
locale-gen
echo "LANG=en_US.UTF-8" > /etc/locale.conf

# Hostname
echo "${HOSTNAME}" > /etc/hostname
cat > /etc/hosts <<HOSTS
127.0.0.1   localhost
::1         localhost
127.0.1.1   ${HOSTNAME}.localdomain ${HOSTNAME}
HOSTS

# Passwords
echo "root:${PASSWORD}" | chpasswd
useradd -m -G wheel -s /bin/bash "${USERNAME}"
echo "${USERNAME}:${PASSWORD}" | chpasswd

# Sudoers
sed -i 's/^# %wheel ALL=(ALL:ALL) ALL/%wheel ALL=(ALL:ALL) ALL/' /etc/sudoers

# NetworkManager — will pick up the copied profiles on first boot
systemctl enable NetworkManager

# ── GRUB — Windows entry 0 (fixed default), Arch entry 1 ─────────────────────

# Enable os-prober
sed -i 's/#GRUB_DISABLE_OS_PROBER=false/GRUB_DISABLE_OS_PROBER=false/' /etc/default/grub
grep -q 'GRUB_DISABLE_OS_PROBER' /etc/default/grub \
  || echo 'GRUB_DISABLE_OS_PROBER=false' >> /etc/default/grub

# GRUB_DEFAULT=0  →  always boots the FIRST entry (Windows), never changes
sed -i 's/^GRUB_DEFAULT=.*/GRUB_DEFAULT=0/' /etc/default/grub

# Remove any SAVEDEFAULT line — we want a fixed default, not a remembered one
sed -i '/^GRUB_SAVEDEFAULT/d' /etc/default/grub

# Show menu for 10 seconds with visible countdown
sed -i 's/^GRUB_TIMEOUT=.*/GRUB_TIMEOUT=10/' /etc/default/grub

# Always show the menu (never hidden/countdown-only)
sed -i 's/^GRUB_TIMEOUT_STYLE=.*/GRUB_TIMEOUT_STYLE=menu/' /etc/default/grub
grep -q '^GRUB_TIMEOUT_STYLE' /etc/default/grub \
  || echo 'GRUB_TIMEOUT_STYLE=menu' >> /etc/default/grub

# Readable boot (no quiet/splash)
sed -i 's/^GRUB_CMDLINE_LINUX_DEFAULT=.*/GRUB_CMDLINE_LINUX_DEFAULT=""/' /etc/default/grub

# ── 09_windows: emit the Windows chainloader entry BEFORE 10_linux ────────────
# grub.cfg entry order = script filename order, so 09 < 10 < 30.
# This guarantees:  index 0 = Windows,  index 1 = Arch Linux.
# We then disable 30_os-prober so Windows doesn't appear twice.

cat > /etc/grub.d/09_windows <<'WINSCRIPT'
#!/bin/sh
# Place Windows Boot Manager as GRUB entry 0 (before Arch Linux at entry 1).
set -e
. /usr/share/grub/grub-mkconfig_lib

OSPROBED=\$(os-prober 2>/dev/null || true)
[ -z "\$OSPROBED" ] && exit 0

echo "\$OSPROBED" | while IFS=: read -r PART LONG SHORT BOOT; do
  case "\$BOOT" in
    chain|efi)
      UUID=\$(blkid -s UUID -o value "\$PART" 2>/dev/null || true)
      echo "menuentry '\${LONG}' --class windows --class os \$GRUB_CLASS {"
      echo "    insmod part_gpt"
      echo "    insmod fat"
      echo "    insmod chain"
      if [ -n "\$UUID" ]; then
        echo "    search --no-floppy --fs-uuid --set=root \${UUID}"
      fi
      echo "    chainloader /EFI/Microsoft/Boot/bootmgfw.efi"
      echo "}"
      ;;
  esac
done
WINSCRIPT

chmod +x /etc/grub.d/09_windows

# Disable 30_os-prober to prevent Windows appearing a second time at a later index
chmod -x /etc/grub.d/30_os-prober

# Install GRUB to the EFI partition
grub-install \
  --target=x86_64-efi \
  --efi-directory=/boot/efi \
  --bootloader-id=GRUB \
  --recheck

# Generate grub.cfg  (order: 09_windows → 10_linux → others)
grub-mkconfig -o /boot/grub/grub.cfg

echo "[OK] grub.cfg generated."
echo "[OK] Entry 0 = Windows (GRUB_DEFAULT=0, always boots after timeout)."
echo "[OK] Entry 1 = Arch Linux (press Down arrow + Enter to select)."

CHROOT

# ── done ─────────────────────────────────────────────────────────────────────
echo ""
success "═══════════════════════════════════════════════"
success "  Installation complete!"
success "═══════════════════════════════════════════════"
echo ""
info "Summary:"
echo -e "  Root partition : ${ROOT_PART}"
echo -e "  EFI partition  : ${EFI_PART}"
echo -e "  Hostname       : ${HOSTNAME}"
echo -e "  User           : ${USERNAME}"
echo -e "  Timezone       : ${TIMEZONE}"
echo ""
info "GRUB boot menu (10-second countdown):"
echo -e "  ${BOLD}Entry 0${NC} — Windows   ← default, boots automatically every time"
echo -e "  ${BOLD}Entry 1${NC} — Arch Linux ← press ${BOLD}↓${NC} then Enter"
echo ""
if [[ "$WIFI_IWD" == true || "$WIFI_NM" == true ]]; then
  success "WiFi profiles copied — internet should work immediately on first boot."
else
  warn "No WiFi profiles were copied. Run 'nmtui' after first boot to connect."
fi
echo ""
warn "Unmounting and rebooting in 5 seconds… (Ctrl-C to cancel)"
sleep 5
umount -R /mnt
reboot
