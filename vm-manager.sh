#!/usr/bin/env bash
# =============================================================================
# vm.sh — macOS Xen VM Helper Script
#         Start/stop/manage VM, mount EFI partition, manage disks
# =============================================================================
set -euo pipefail

# Colors
RED='\033[0;31m'; GRN='\033[0;32m'; YEL='\033[1;33m'
BLU='\033[0;34m'; CYA='\033[0;36m'; RST='\033[0m'; BLD='\033[1m'

log()  { echo -e "${BLU}[$(date +%H:%M:%S)]${RST} $*"; }
ok()   { echo -e "${GRN}[✔]${RST} $*"; }
warn() { echo -e "${YEL}[!]${RST} $*"; }
die()  { echo -e "${RED}[✘]${RST} $*" >&2; exit 1; }
sep()  { echo -e "${CYA}────────────────────────────────────────────────────${RST}"; }

# ── Configuration ──────────────────────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VM_NAME="${SCRIPT_DIR##*/}"  # Directory name = VM name
MACOS_DISK="${SCRIPT_DIR}/macos.qcow2"
OPENCORE_IMG="${SCRIPT_DIR}/OpenCore.img"
RECOVERY_IMG="${SCRIPT_DIR}/BaseSystem.img"
EFI_MOUNT="${SCRIPT_DIR}/EFI"
XL_CONFIG="${SCRIPT_DIR}/${VM_NAME}.cfg"

# Check if running as root for xl commands
if [[ "$(id -u)" -ne 0 ]]; then
  SUDO="sudo"
else
  SUDO=""
fi

# ── EFI Mounting Functions ─────────────────────────────────────────────────────
efi_mount() {
  sep
  log "Montage partition EFI..."
  
  [[ -f "${OPENCORE_IMG}" ]] || die "OpenCore.img introuvable : ${OPENCORE_IMG}"
  
  # Create mount point if needed
  mkdir -p "${EFI_MOUNT}"
  
  # Check if already mounted
  if mountpoint -q "${EFI_MOUNT}" 2>/dev/null; then
    warn "EFI déjà monté à ${EFI_MOUNT}"
    return 0
  fi
  
  # Find loop device for OpenCore.img
  local LOOP_DEV
  LOOP_DEV=$($SUDO losetup -f)
  
  # Attach image to loop device
  log "Attachement ${OPENCORE_IMG} → ${LOOP_DEV}..."
  $SUDO losetup "${LOOP_DEV}" "${OPENCORE_IMG}"
  
  # Scan partitions
  $SUDO partprobe "${LOOP_DEV}" 2>/dev/null || true
  sleep 1
  
  # Find EFI partition (usually p1)
  local EFI_PARTITION="${LOOP_DEV}p1"
  
  if [[ ! -e "${EFI_PARTITION}" ]]; then
    warn "Partition ${EFI_PARTITION} non trouvée, essai avec p2..."
    EFI_PARTITION="${LOOP_DEV}p2"
  fi
  
  if [[ ! -e "${EFI_PARTITION}" ]]; then
    $SUDO losetup -d "${LOOP_DEV}"
    die "Impossible de trouver la partition EFI sur ${LOOP_DEV}"
  fi
  
  # Mount EFI partition (FAT32)
  log "Montage ${EFI_PARTITION} sur ${EFI_MOUNT}..."
  $SUDO mount -t vfat "${EFI_PARTITION}" "${EFI_MOUNT}" || {
    $SUDO losetup -d "${LOOP_DEV}"
    die "Montage EFI échoué"
  }
  
  ok "EFI monté : ${EFI_MOUNT}"
  ok "Loop device : ${LOOP_DEV}"
  echo "${LOOP_DEV}" > "${SCRIPT_DIR}/.efi_loop"
  
  # List contents
  log "Contenu EFI :"
  $SUDO ls -lh "${EFI_MOUNT}/"
  sep
}

efi_umount() {
  sep
  log "Démontage partition EFI..."
  
  if ! mountpoint -q "${EFI_MOUNT}" 2>/dev/null; then
    warn "EFI non monté"
    return 0
  fi
  
  # Unmount
  $SUDO umount "${EFI_MOUNT}" || die "Impossible de démonter ${EFI_MOUNT}"
  ok "EFI démonté"
  
  # Detach loop device
  if [[ -f "${SCRIPT_DIR}/.efi_loop" ]]; then
    local LOOP_DEV
    LOOP_DEV=$(cat "${SCRIPT_DIR}/.efi_loop")
    $SUDO losetup -d "${LOOP_DEV}" 2>/dev/null && ok "Loop device détaché" || warn "Détachement loop échoué"
    rm -f "${SCRIPT_DIR}/.efi_loop"
  fi
  
  sep
}

efi_edit() {
  sep
  log "Édition config.plist dans EFI..."
  
  efi_mount
  
  local PLIST="${EFI_MOUNT}/EFI/OC/config.plist"
  
  if [[ ! -f "${PLIST}" ]]; then
    die "config.plist non trouvé : ${PLIST}"
  fi
  
  ok "Ouverture avec nano..."
  $SUDO nano "${PLIST}"
  
  ok "config.plist modifié"
  efi_umount
}

efi_backup() {
  sep
  log "Sauvegarde EFI..."
  
  local BACKUP="${SCRIPT_DIR}/EFI-backup-$(date +%Y%m%d-%H%M%S).tar.gz"
  
  efi_mount
  
  $SUDO tar -czf "${BACKUP}" -C "${EFI_MOUNT}" . || die "Sauvegarde échouée"
  
  ok "Sauvegarde créée : ${BACKUP}"
  efi_umount
  
  sep
}

efi_restore() {
  sep
  log "Restauration EFI..."
  
  local BACKUP="$1"
  [[ -f "${BACKUP}" ]] || die "Fichier sauvegarde introuvable : ${BACKUP}"
  
  efi_mount
  
  $SUDO rm -rf "${EFI_MOUNT}"/*
  $SUDO tar -xzf "${BACKUP}" -C "${EFI_MOUNT}" || die "Restauration échouée"
  
  ok "EFI restauré depuis ${BACKUP}"
  efi_umount
  
  sep
}

# ── VM Control Functions ───────────────────────────────────────────────────────
vm_start() {
  sep
  log "Démarrage VM ${VM_NAME}..."
  
  if vm_status &>/dev/null; then
    warn "VM déjà en cours d'exécution"
    return 0
  fi
  
  [[ -f "${MACOS_DISK}" ]] || die "Disque macOS introuvable : ${MACOS_DISK}"
  [[ -f "${OPENCORE_IMG}" ]] || die "OpenCore.img introuvable : ${OPENCORE_IMG}"
  
  # Generate config if needed
  if [[ ! -f "${XL_CONFIG}" ]]; then
    log "Génération config xl..."
    gen_xl_config
  fi
  
  $SUDO xl create "${XL_CONFIG}"
  ok "VM lancée"
  
  log "Récupération domaine ID..."
  sleep 1
  vm_status
  sep
}

vm_start_install() {
  sep
  log "Démarrage VM ${VM_NAME} en mode installation..."
  
  [[ -f "${RECOVERY_IMG}" ]] || die "BaseSystem.img introuvable : ${RECOVERY_IMG}"
  
  # Create install config if needed
  local INSTALL_CONFIG="${SCRIPT_DIR}/${VM_NAME}-install.cfg"
  if [[ ! -f "${INSTALL_CONFIG}" ]]; then
    log "Génération config xl (mode installation)..."
    gen_xl_config_install
  fi
  
  $SUDO xl create "${INSTALL_CONFIG}"
  ok "VM lancée en mode installation"
  
  sleep 1
  vm_status
  sep
}

vm_stop() {
  sep
  log "Arrêt propre VM ${VM_NAME} (ACPI)..."
  
  local DOMID
  DOMID=$(get_domain_id) || { warn "VM non active"; return 0; }
  
  $SUDO xl shutdown "${DOMID}"
  
  # Wait for shutdown
  for i in {1..30}; do
    if ! vm_status &>/dev/null; then
      ok "VM arrêtée"
      sep
      return 0
    fi
    sleep 1
  done
  
  warn "Arrêt ACPI timeout, forçage..."
  vm_kill
}

vm_kill() {
  sep
  log "Forçage arrêt VM ${VM_NAME}..."
  
  local DOMID
  DOMID=$(get_domain_id) || { warn "VM non active"; return 0; }
  
  $SUDO xl destroy "${DOMID}"
  ok "VM détruite"
  sep
}

vm_restart() {
  vm_stop
  sleep 2
  vm_start
}

vm_pause() {
  sep
  log "Suspension VM ${VM_NAME}..."
  
  local DOMID
  DOMID=$(get_domain_id) || die "VM non active"
  
  $SUDO xl pause "${DOMID}"
  ok "VM suspendue"
  sep
}

vm_resume() {
  sep
  log "Reprise VM ${VM_NAME}..."
  
  local DOMID
  DOMID=$(get_domain_id) || die "VM non active"
  
  $SUDO xl unpause "${DOMID}"
  ok "VM reprise"
  sep
}

vm_status() {
  local DOMID
  DOMID=$(get_domain_id) || { echo "VM ${VM_NAME} non active"; return 1; }
  
  echo "VM ${VM_NAME} (domid=${DOMID}) active"
  $SUDO xl list | grep -E "^(Name|${VM_NAME})"
}

get_domain_id() {
  $SUDO xl domid "${VM_NAME}" 2>/dev/null || return 1
}

# ── Display Functions ──────────────────────────────────────────────────────────
vnc_display() {
  sep
  log "Détection affichage VNC..."
  
  local DOMID
  DOMID=$(get_domain_id) || die "VM non active"
  
  # VNC port = 5900 + domid
  local VNC_PORT=$((5900 + DOMID))
  
  ok "VNC disponible sur : localhost:${VNC_PORT}"
  log "Connexion avec vncviewer..."
  
  command -v vncviewer &>/dev/null && {
    vncviewer localhost:${VNC_PORT} &
    sleep 1
  } || warn "vncviewer non trouvé, connexion manuelle : vncviewer localhost:${VNC_PORT}"
  
  sep
}

console_display() {
  sep
  log "Console série VM ${VM_NAME}..."
  
  local DOMID
  DOMID=$(get_domain_id) || die "VM non active"
  
  $SUDO xl console "${DOMID}"
}

# ── Logging Functions ──────────────────────────────────────────────────────────
vm_log() {
  sep
  log "Logs QEMU/Xen pour ${VM_NAME}..."
  
  # Try various log locations
  local LOG_PATHS=(
    "/var/log/xen/qemu-dm-${VM_NAME}.log"
    "/var/log/xen/${VM_NAME}.log"
    "/tmp/${VM_NAME}.log"
  )
  
  for path in "${LOG_PATHS[@]}"; do
    if [[ -f "${path}" ]]; then
      ok "Log trouvé : ${path}"
      $SUDO tail -100 "${path}"
      sep
      return 0
    fi
  done
  
  warn "Log introuvable. Essai avec 'xl dmesg' :"
  $SUDO xl dmesg | tail -50
  sep
}

vm_info() {
  sep
  log "Informations VM ${VM_NAME}..."
  
  local DOMID
  DOMID=$(get_domain_id) || { warn "VM non active"; return 0; }
  
  echo "─ État ─"
  $SUDO xl list | grep -E "^(Name|${VM_NAME})"
  
  echo ""
  echo "─ Domaine ─"
  $SUDO xl dominfo "${DOMID}" || true
  
  echo ""
  echo "─ Disques ─"
  $SUDO xl block-list "${DOMID}" || true
  
  echo ""
  echo "─ Interfaces ─"
  $SUDO xl network-list "${DOMID}" || true
  
  sep
}

# ── Configuration Generation ───────────────────────────────────────────────────
gen_xl_config() {
  cat > "${XL_CONFIG}" << 'EOF'
# Xen HVM VM Configuration — macOS via OpenCore
name = "VM_NAME_PLACEHOLDER"
type = "hvm"
memory = RAM_MB_PLACEHOLDER
maxmem = RAM_MB_PLACEHOLDER
vcpus = CPU_CORES_PLACEHOLDER
maxvcpus = CPU_CORES_PLACEHOLDER

# UEFI/BIOS
firmware = "ovmf"
ovmf = [ "/usr/lib/xen/boot/ovmf.bin", "/usr/lib/xen/boot/ovmf-vars.bin" ]

# Disks
disk = [
    "format=raw,vdev=hda,access=ro,target=OPENCORE_IMG_PLACEHOLDER",
    "format=qcow2,vdev=hdb,target=MACOS_DISK_PLACEHOLDER",
]

# Network
vif = [ "bridge=xenbr0" ]

# I/O
serial = "pty"
vnc = 1
vncunused = 1

# Lifecycle
on_poweroff = "destroy"
on_reboot = "restart"
on_crash = "preserve"
EOF

  # Replace placeholders with actual values
  sed -i "s|VM_NAME_PLACEHOLDER|${VM_NAME}|g" "${XL_CONFIG}"
  sed -i "s|RAM_MB_PLACEHOLDER|8192|g" "${XL_CONFIG}"
  sed -i "s|CPU_CORES_PLACEHOLDER|4|g" "${XL_CONFIG}"
  sed -i "s|OPENCORE_IMG_PLACEHOLDER|${OPENCORE_IMG}|g" "${XL_CONFIG}"
  sed -i "s|MACOS_DISK_PLACEHOLDER|${MACOS_DISK}|g" "${XL_CONFIG}"
  
  ok "Config Xen créée : ${XL_CONFIG}"
}

gen_xl_config_install() {
  cat > "${SCRIPT_DIR}/${VM_NAME}-install.cfg" << 'EOF'
# Xen HVM VM Configuration — macOS Installation
name = "VM_NAME_PLACEHOLDER-install"
type = "hvm"
memory = RAM_MB_PLACEHOLDER
maxmem = RAM_MB_PLACEHOLDER
vcpus = CPU_CORES_PLACEHOLDER
maxvcpus = CPU_CORES_PLACEHOLDER

# UEFI/BIOS
firmware = "ovmf"
ovmf = [ "/usr/lib/xen/boot/ovmf.bin", "/usr/lib/xen/boot/ovmf-vars.bin" ]

# Disks (+ BaseSystem for installation)
disk = [
    "format=raw,vdev=hda,access=ro,target=OPENCORE_IMG_PLACEHOLDER",
    "format=qcow2,vdev=hdb,target=MACOS_DISK_PLACEHOLDER",
    "format=raw,vdev=hdc,target=RECOVERY_IMG_PLACEHOLDER",
]

# Network
vif = [ "bridge=xenbr0" ]

# I/O
serial = "pty"
vnc = 1
vncunused = 1

# Lifecycle
on_poweroff = "destroy"
on_reboot = "restart"
on_crash = "preserve"
EOF

  # Replace placeholders
  sed -i "s|VM_NAME_PLACEHOLDER|${VM_NAME}|g" "${SCRIPT_DIR}/${VM_NAME}-install.cfg"
  sed -i "s|RAM_MB_PLACEHOLDER|8192|g" "${SCRIPT_DIR}/${VM_NAME}-install.cfg"
  sed -i "s|CPU_CORES_PLACEHOLDER|4|g" "${SCRIPT_DIR}/${VM_NAME}-install.cfg"
  sed -i "s|OPENCORE_IMG_PLACEHOLDER|${OPENCORE_IMG}|g" "${SCRIPT_DIR}/${VM_NAME}-install.cfg"
  sed -i "s|MACOS_DISK_PLACEHOLDER|${MACOS_DISK}|g" "${SCRIPT_DIR}/${VM_NAME}-install.cfg"
  sed -i "s|RECOVERY_IMG_PLACEHOLDER|${RECOVERY_IMG}|g" "${SCRIPT_DIR}/${VM_NAME}-install.cfg"
  
  ok "Config installation créée : ${SCRIPT_DIR}/${VM_NAME}-install.cfg"
}

# ── Usage ──────────────────────────────────────────────────────────────────────
usage() {
cat <<EOF
${BLD}Usage :${RST} $(basename "$0") <command> [options]

${BLD}VM Control :${RST}
  start              Démarrer la VM normalement
  start-install      Démarrer en mode installation (+ BaseSystem)
  stop               Arrêt propre (ACPI)
  kill               Forcer arrêt
  restart            Redémarrer
  pause              Suspendre
  resume             Reprendre
  status             État VM

${BLD}EFI Partition :${RST}
  efi-mount          Monter la partition EFI
  efi-umount         Démonter la partition EFI
  efi-edit           Éditer config.plist (monte automatiquement)
  efi-backup         Sauvegarder EFI (tar.gz)
  efi-restore FILE   Restaurer EFI depuis sauvegarde

${BLD}Display & Logs :${RST}
  vnc                Afficher VNC (connexion automatique si vncviewer dispo)
  console            Console série
  log                Voir logs QEMU/Xen
  info               Infos détaillées

${BLD}Exemples :${RST}
  ./vm.sh start                    # Démarrer normalement
  ./vm.sh start-install            # Installation macOS
  ./vm.sh efi-edit                 # Éditer OpenCore config
  ./vm.sh efi-backup               # Sauvegarder EFI
  ./vm.sh vnc                      # Connexion VNC
  ./vm.sh log                      # Voir logs de la VM

EOF
exit 0
}

# ── Main ───────────────────────────────────────────────────────────────────────
[[ $# -eq 0 ]] && usage

case "$1" in
  start)          vm_start ;;
  start-install)  vm_start_install ;;
  stop)           vm_stop ;;
  kill)           vm_kill ;;
  restart)        vm_restart ;;
  pause)          vm_pause ;;
  resume)         vm_resume ;;
  status)         vm_status ;;
  
  efi-mount)      efi_mount ;;
  efi-umount)     efi_umount ;;
  efi-edit)       efi_edit ;;
  efi-backup)     efi_backup ;;
  efi-restore)    efi_restore "$2" ;;
  
  vnc)            vnc_display ;;
  console)        console_display ;;
  log)            vm_log ;;
  info)           vm_info ;;
  
  help|-h|--help) usage ;;
  *)              die "Commande inconnue : $1" ;;
esac
