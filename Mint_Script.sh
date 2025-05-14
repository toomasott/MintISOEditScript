#!/bin/bash
# Linux Mint Xfce ISO modification script. 

### CONFIGURATION AND VARIABLES ###
BASIC_ISO="linuxmint-basic.iso"
CUSTOM_ISO="linuxmint-custom.iso"
CONFIG_FILES="config_files"
WORK_DIR="work"
SQUASHFS_DIR="$WORK_DIR/squashfs-root"
MOUNT_DIR="$WORK_DIR/mount"

set -e  # Exit on error
if [ "$(id -u)" -ne 0 ]; then
    echo "This script must be run as root!" >&2
    exit 1
fi

# Ensure ISO-file
if [ ! -f "$BASIC_ISO" ]; then
    echo "$BASIC_ISO not found. Downloading latest Linux Mint Xfce ISO-file."
    MIRROR_URL="https://mirrors.edge.kernel.org/linuxmint/stable"
    LATEST_VERSION=$(curl -s "$MIRROR_URL/" | grep -oP 'href="\K[0-9.]+(?=/")' | sort -V | tail -n 1)
    ISO_URL="${MIRROR_URL}/${LATEST_VERSION}/linuxmint-${LATEST_VERSION}-xfce-64bit.iso"
    wget -q --show-progress -O "$BASIC_ISO" "$ISO_URL"
    chmod 777 $BASIC_ISO
fi

# Ensure config files
if [ ! -d "$CONFIG_FILES" ]; then
    echo "$CONFIG_FILES not found. Downloading Linux Mint Xfce config files."
    apt update && apt install -y git
    git clone https://github.com/toomasott/MintConfigFiles "$CONFIG_FILES"
    chmod -R 777 "$CONFIG_FILES"
fi

#Cleanup (just in case)
for path in "$MOUNT_DIR" "$SQUASHFS_DIR"/dev/pts "$SQUASHFS_DIR"/dev "$SQUASHFS_DIR"/sys "$SQUASHFS_DIR"/proc; do
    umount -lf "$path" 2>/dev/null || true
done
rm -rf "$WORK_DIR"

# Install necessary packages for the script
apt update && apt install -y squashfs-tools xorriso curl rsync isolinux syslinux-utils
 
### 1. Extract Original ISO ###
mkdir -p "$WORK_DIR" "$MOUNT_DIR" "$SQUASHFS_DIR"
echo "Extracting ISO..."
mount -o loop "$BASIC_ISO" "$MOUNT_DIR"
rsync -a "$MOUNT_DIR/" "$WORK_DIR/"
umount "$MOUNT_DIR"

### 2. Add Preseed File for Automated Installation ###
echo "Adding Preseed File..."
cat <<EOF > "$WORK_DIR/preseed.cfg"
d-i debian-installer/locale string et_EE
d-i localechooser/supported-locales multiselect et_EE.UTF-8, en_US.UTF-8
d-i keyboard-configuration/layoutcode string et,us,ru
d-i keyboard-configuration/variantcode string ,,,
d-i keyboard-configuration/optionscode string grp:alt_shift_toggle

d-i hw-detect/load_firmware boolean true
 
d-i netcfg/choose_interface select auto
d-i netcfg/get_hostname string unassigned-hostname
d-i netcfg/get_domain string unassigned-domain
 
d-i passwd/user-fullname string Arvuti Kasutaja
d-i passwd/username string kasutaja
d-i passwd/user-password kasutaja
d-i passwd/user-password-again kasutaja
d-i passwd/user-default-groups string sudo audio cdrom video plugdev

d-i clock-setup/utc boolean true
d-i time/zone string Europe/Tallinn
d-i clock-setup/ntp boolean true
d-i clock-setup/ntp-server string ntp.eenet.ee
 
d-i partman-auto/method string regular
d-i partman/choose_partition select finish
d-i partman/confirm boolean true
d-i partman/confirm_nooverwrite boolean true

d-i apt-setup/cdrom/set-first boolean false
d-i apt-setup/non-free-firmware boolean true
d-i apt-setup/non-free boolean true
d-i apt-setup/contrib boolean true
d-i apt-setup/services-select multiselect security, updates
 
d-i pkgsel/include string linux-image-generic-hwe-24.04
d-i pkgsel/upgrade select full-upgrade
 
d-i grub-installer/only_debian boolean true
d-i grub-installer/with_other_os boolean true
 
d-i finish-install/reboot_in_progress note
EOF

### 3. Extract filesystem.squashfs ###
echo "Extracting filesystem.squashfs..."
unsquashfs -f -d "$SQUASHFS_DIR" "$WORK_DIR/casper/filesystem.squashfs"
### 4. Modify the Live System (Inside filesystem.squashfs) ###
echo "Customizing Live System..."
# Prepare chroot environment
mount -t proc none "$SQUASHFS_DIR/proc" && mount -t sysfs none "$SQUASHFS_DIR/sys" && mount -o bind /dev "$SQUASHFS_DIR/dev" && mount -o bind /dev/pts "$SQUASHFS_DIR/dev/pts"


# Copy resolv.conf for network access
cp /etc/resolv.conf "$SQUASHFS_DIR/etc/resolv.conf"

# ---Add configs---
# XFCE4
mkdir -p "$SQUASHFS_DIR/etc/skel/.config/xfce4"
cp -r "$CONFIG_FILES/xfce4/"* "$SQUASHFS_DIR/etc/skel/.config/xfce4/"
# PCManFM
mkdir -p "$SQUASHFS_DIR/etc/skel/.config/pcmanfm"
cp -r "$CONFIG_FILES/pcmanfm/"* "$SQUASHFS_DIR/etc/skel/.config/pcmanfm/"
# Brave
mkdir -p "$SQUASHFS_DIR/etc/skel/.config/BraveSoftware"
cp -r "$CONFIG_FILES/BraveSoftware/"* "$SQUASHFS_DIR/etc/skel/.config/BraveSoftware/"
# mimeapps
mkdir -p "$SQUASHFS_DIR/etc/skel/.config"
cp -r "$CONFIG_FILES/mimeapps.list" "$SQUASHFS_DIR/etc/skel/.config/mimeapps.list"
# Firefox
mkdir -p "$SQUASHFS_DIR/etc/skel/.mozilla/firefox"
cp -r "$CONFIG_FILES/firefox/"* "$SQUASHFS_DIR/etc/skel/.mozilla/firefox/"

# Create and configure the user
echo "Creating user inside chroot..."
chroot "$SQUASHFS_DIR" useradd -m -u 1000 -s /bin/bash -c "Arvuti Kasutaja" -G sudo kasutaja
echo "kasutaja:kasutaja" | chroot "$SQUASHFS_DIR" chpasswd
echo "kasutaja ALL=(ALL) NOPASSWD:ALL" > "$SQUASHFS_DIR/etc/sudoers.d/99-kasutaja"
chmod 0440 "$SQUASHFS_DIR/etc/sudoers.d/99-kasutaja"
cat <<EOF > "$SQUASHFS_DIR/etc/lightdm/lightdm.conf"
[Seat:*]
autologin-user=kasutaja
autologin-user-timeout=0
user-session=xfce
EOF

# ---Install software---
# Basic packages
chroot "$SQUASHFS_DIR" bash -c 'export DEBIAN_FRONTEND=noninteractive;
    apt purge -y thunar* xreader* libreoffice-* && \
    apt-get update && apt-get install -y curl software-properties-common pcmanfm atril mc htop mpv exif flameshot webp-pixbuf-loader vlc && \
    flatpak remote-add --if-not-exists flathub https://flathub.org/repo/flathub.flatpakrepo && \
    flatpak update -y && flatpak install -y flathub org.libreoffice.LibreOffice org.libreoffice.LibreOffice.Locale'
# Brave browser
chroot "$SQUASHFS_DIR" bash -c 'export DEBIAN_FRONTEND=noninteractive; curl -fsS https://dl.brave.com/install.sh | sh'
# Wget config script download
chroot "$SQUASHFS_DIR" su - kasutaja -c 'wget -O ~/wget-conf-linuxmint-user.sh https://enos.itcollege.ee/~edmund/linux/wget-config-scripts/wget-conf-linuxmint-user.txt && \
    sh ~/wget-conf-linuxmint-user.sh && rm ~/wget-conf-linuxmint-user.sh'
# Estonian ID Card Software
chroot "$SQUASHFS_DIR" su - kasutaja -c 'export DEBIAN_FRONTEND=noninteractive; \
    curl -sSL https://installer.id.ee/media/install-scripts/install-open-eid.sh -o /tmp/install-open-eid.sh && \
    sed -i "/xdg-open/d" /tmp/install-open-eid.sh && \
    chmod +x /tmp/install-open-eid.sh && yes | /tmp/install-open-eid.sh && rm /tmp/install-open-eid.sh'
# DWService
chroot "$SQUASHFS_DIR" bash -c 'export DEBIAN_FRONTEND=noninteractive; \
    curl -sSL https://www.dwservice.net/download/dwagent.sh -o /usr/local/bin/dwagent.sh && chmod +x /usr/local/bin/dwagent.sh'
cat <<EOF > "$SQUASHFS_DIR/usr/share/applications/dwservice.desktop"
[Desktop Entry]
Name=Kaughaldus
GenericName=Kaughaldus
Comment=Kaughaldus
Exec=/usr/local/bin/dwagent.sh
StartupNotify=true
Terminal=false
Icon=remote-desktop
Type=Application
Categories=Network;
EOF
chmod 644 "$SQUASHFS_DIR/usr/share/applications/dwservice.desktop" && chown root:root "$SQUASHFS_DIR/usr/share/applications/dwservice.desktop"


# Set default locale and timezone
chroot "$SQUASHFS_DIR" bash -c "apt remove -y \$(apt list --installed | grep -E 'language-pack|hunspell|mythes' | grep -v -E 'en|et_EE' | cut -d/ -f1) 2>/dev/null"
chroot "$SQUASHFS_DIR" bash -c "sed -i 's/^/#/' /etc/locale.gen"
echo "et_EE.UTF-8 UTF-8" > "$SQUASHFS_DIR/etc/locale.gen" && echo "en_US.UTF-8 UTF-8" >> "$SQUASHFS_DIR/etc/locale.gen"
chroot "$SQUASHFS_DIR" bash -c "rm -f /usr/lib/locale/locale-archive"
chroot "$SQUASHFS_DIR" bash -c "locale-gen --purge en_US.UTF-8 et_EE.UTF-8"
echo "LANG=et_EE.UTF-8" > "$SQUASHFS_DIR/etc/default/locale" && echo "LC_ALL=et_EE.UTF-8" >> "$SQUASHFS_DIR/etc/default/locale"
ln -sf /usr/share/zoneinfo/Europe/Tallinn "$SQUASHFS_DIR/etc/localtime"
echo "Europe/Tallinn" > "$SQUASHFS_DIR/etc/timezone"


# Set keyboard layout
cat <<EOF > "$SQUASHFS_DIR/etc/default/keyboard"
XKBMODEL="pc105"
XKBLAYOUT="ee,us,ru"
XKBVARIANT=",,"
XKBOPTIONS="grp:alt_shift_toggle"
EOF

  
# Clean up chroot environment and unmount chroot filesystems
chroot "$SQUASHFS_DIR" bash -c 'apt clean && apt autoclean && apt autoremove -y && rm -rf /usr/share/{man,doc}/* /etc/resolv.conf'
chroot "$SQUASHFS_DIR" find /usr/share/locale -mindepth 1 -maxdepth 1 \( -name "et*" -o -name "en*" \) -prune -o -exec rm -rf {} \;
umount "$SQUASHFS_DIR/dev/pts" && umount "$SQUASHFS_DIR/dev" && umount "$SQUASHFS_DIR/sys" && umount "$SQUASHFS_DIR/proc"
 
### 5. Repack filesystem.squashfs ###
echo "Repacking filesystem.squashfs..."
rm -f "$WORK_DIR/casper/filesystem.squashfs"
mksquashfs "$SQUASHFS_DIR" "$WORK_DIR/casper/filesystem.squashfs" -comp zstd -Xcompression-level 22 -b 1M -noappend
 
# Update manifest file
cd "$WORK_DIR"
chmod +w md5sum.txt
find . -type f -print0 | xargs -0 md5sum | grep -v md5sum.txt > md5sum.txt
chmod -w md5sum.txt
cd ..

# Modify ISOLINUX timeout (BIOS boot)
if [ -f "$WORK_DIR/isolinux/isolinux.cfg" ]; then
    echo "Modifying ISOLINUX configuration for BIOS..."
    sed -i 's/^\(timeout\s*\).*$/\1 0/' "$WORK_DIR/isolinux/isolinux.cfg"
fi
# Modify GRUB timeout (UEFI boot)
if [ -f "$WORK_DIR/boot/grub/grub.cfg" ]; then
    echo "Modifying GRUB configuration for UEFI..."
    sed -i 's/^\(set timeout=\).*/\1 0/' "$WORK_DIR/boot/grub/grub.cfg"
fi
 
### 6. Rebuild ISO ###
echo "Rebuilding ISO..."
xorriso -as mkisofs \
  -iso-level 3 \
  -rock \
  -isohybrid-mbr /usr/lib/ISOLINUX/isohdpfx.bin \
  -c isolinux/boot.cat \
  -b isolinux/isolinux.bin \
  -no-emul-boot -boot-load-size 4 -boot-info-table \
  -eltorito-alt-boot \
  -e boot/grub/efi.img \
  -no-emul-boot \
  -isohybrid-gpt-basdat \
  -volid "CUSTOM_MINT" \
  -output "$CUSTOM_ISO" \
  "$WORK_DIR"

isohybrid --uefi "$CUSTOM_ISO"

echo "Custom ISO created: $CUSTOM_ISO"

echo "Cleaning up..."
umount -Rl "$SQUASHFS_DIR" || true
rm -rf "$SQUASHFS_DIR" "$MOUNT_DIR"
