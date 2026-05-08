#!/usr/bin/env bash
set -euo pipefail

# Setup by errorcat and Gemini

# Config
ADMIN_USER='admin'
MAIN_USER='shimo'

read -s -p "Enter password: " PASSWORD
echo

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BACKUP_DIR="$SCRIPT_DIR/shimo-backup"

log() {
  printf '\n== %s ==\n' "$*"
}

copy_dir() {
  local src="$1"
  local dst="$2"
  if [[ -d "$src" ]]; then
    mkdir -p "$dst"
    rsync -aHAX "$src"/ "$dst"/
  else
    echo "Warning: Source $src not found, skipping."
  fi
}

if [[ ! -d "$BACKUP_DIR" ]]; then
    echo "Error: Directory $BACKUP_DIR not found!"
    exit 1
fi

log "Installing base tools"
apt update
apt install -y rsync acl curl gnupg ca-certificates git xrdp openssh-server firefox preload dconf-cli cinnamon-core cinnamon-session plymouth-themes

log "Adding VS Code and Sublime repos"
install -d /usr/share/keyrings
curl -fsSL https://packages.microsoft.com/keys/microsoft.asc | gpg --dearmor -o /usr/share/keyrings/microsoft.gpg
echo "deb [arch=amd64 signed-by=/usr/share/keyrings/microsoft.gpg] https://packages.microsoft.com/repos/code stable main" > /etc/apt/sources.list.d/vscode.list

curl -fsSL https://download.sublimetext.com/sublimehq-pub.gpg | gpg --dearmor -o /usr/share/keyrings/sublimehq.gpg
echo "deb [signed-by=/usr/share/keyrings/sublimehq.gpg] https://download.sublimetext.com/ apt/stable/" > /etc/apt/sources.list.d/sublime-text.list

apt update
apt install -y code sublime-text

log "Creating users"
id "$ADMIN_USER" &>/dev/null || useradd -m -s /bin/bash "$ADMIN_USER"
echo "${ADMIN_USER}:${PASSWORD}" | chpasswd
usermod -aG sudo "$ADMIN_USER"

id "$MAIN_USER" &>/dev/null || useradd -m -s /bin/bash "$MAIN_USER"
echo "${MAIN_USER}:${PASSWORD}" | chpasswd

log "Installing custom icons"
if [[ -d "$BACKUP_DIR/Custom" ]]; then
    copy_dir "$BACKUP_DIR/Custom" "/usr/share/icons/Custom"
fi

log "Restoring files"
mkdir -p "/home/$MAIN_USER"
copy_dir "$BACKUP_DIR/home/$MAIN_USER/.config" "/home/$MAIN_USER/.config"
copy_dir "$BACKUP_DIR/home/$MAIN_USER/.local/share" "/home/$MAIN_USER/.local/share"
copy_dir "$BACKUP_DIR/home/$MAIN_USER/.themes" "/home/$MAIN_USER/.themes"
copy_dir "$BACKUP_DIR/home/$MAIN_USER/.icons" "/home/$MAIN_USER/.icons"
copy_dir "$BACKUP_DIR/home/$MAIN_USER/.mozilla/firefox" "/home/$MAIN_USER/.mozilla/firefox"

# --- БЛОК БЕСШОВНОЙ ЗАГРУЗКИ ДЛЯ INTEL (Deus Ex) ---
log "Configuring Intel-specific seamless boot (i915 Fastboot + Deus Ex)"
PLYMOUTH_PATH="/usr/share/plymouth/themes/deus_ex"
SRC_PLYMOUTH="$BACKUP_DIR/usr/share/plymouth/themes/deus_ex"

if [[ -d "$SRC_PLYMOUTH" ]]; then
    copy_dir "$SRC_PLYMOUTH" "$PLYMOUTH_PATH"
    
    # Регистрация темы
    update-alternatives --install /usr/share/plymouth/themes/default.plymouth default.plymouth "$PLYMOUTH_PATH/deus_ex.plymouth" 200 || true
    update-alternatives --set default.plymouth "$PLYMOUTH_PATH/deus_ex.plymouth" || true

    # Настройка Daemon для мгновенного появления
    cat > /etc/plymouth/plymouthd.conf <<EOF
[Daemon]
Theme=deus_ex
ShowDelay=0
DeviceTimeout=8
EOF

    # 1. Настройка GRUB (Intel Fastboot + Подавление вывода)
    if grep -q "GRUB_CMDLINE_LINUX_DEFAULT" /etc/default/grub; then
        # Устанавливаем параметры: 
        # i915.fastboot=1 — не сбрасывать видеорежим
        # loglevel=0 и systemd.show_status=false — полная тишина в консоли
        # vt.global_cursor_default=0 — убрать мигающий курсор
        sed -i 's/GRUB_CMDLINE_LINUX_DEFAULT=.*/GRUB_CMDLINE_LINUX_DEFAULT="quiet splash i915.fastboot=1 i915.enable_fbc=1 loglevel=0 systemd.show_status=false vt.global_cursor_default=0"/' /etc/default/grub
    fi

    # Сохраняем видеобуфер GRUB для ядра (убирает моргание при передаче управления)
    if ! grep -q "^GRUB_GFXPAYLOAD_LINUX=keep" /etc/default/grub; then
        echo "GRUB_GFXPAYLOAD_LINUX=keep" >> /etc/default/grub
    fi

    # 2. Early KMS для Intel (драйвер грузится в initramfs)
    MODULES_FILE="/etc/initramfs-tools/modules"
    for mod in intel_agp i915; do
        if ! grep -q "^$mod" "$MODULES_FILE"; then
            echo "$mod" >> "$MODULES_FILE"
        fi
    done

    # Принудительный фреймбуфер
    echo "FRAMEBUFFER=y" > /etc/initramfs-tools/conf.d/splash

    log "Updating GRUB and Initramfs (this may take a while)"
    update-grub
    update-initramfs -u
else
    log "Warning: Deus Ex theme not found in backup"
fi

log "Finalizing permissions"
chown -R "$MAIN_USER:$MAIN_USER" "/home/$MAIN_USER"

log "Setting ACL for admin on shimo home"
setfacl -R -m u:"$ADMIN_USER":rx "/home/$MAIN_USER" || true
find "/home/$MAIN_USER" -type d -exec setfacl -m d:u:"$ADMIN_USER":rx {} + || true

log "Cleaning sudo from shimo"
deluser "$MAIN_USER" sudo 2>/dev/null || true

log "Done"
echo "Reboot recommended"