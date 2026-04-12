#!/usr/bin/env bash
# =============================================================================
#  vm.sh — Gestion VM macOS @@MACOS_VERSION@@ (Xen HVM)
#
#  Ce fichier est copié dans ~/VMs/macos-@@MACOS_VERSION@@/ par le script
#  setup-macos-vm-xen.sh. Les variables @@...@@ sont substituées au moment
#  de la copie.
#
#  Usage : ./vm.sh <commande> [options]
# =============================================================================
set -euo pipefail

# ── Couleurs ──────────────────────────────────────────────────────────────────
RED='\033[0;31m'; GRN='\033[0;32m'; YEL='\033[1;33m'
BLU='\033[0;34m'; CYA='\033[0;36m'; RST='\033[0m'; BLD='\033[1m'
ok()   { echo -e "${GRN}[✔]${RST} $*"; }
warn() { echo -e "${YEL}[!]${RST} $*"; }
err()  { echo -e "${RED}[✘]${RST} $*" >&2; }
info() { echo -e "${BLU}[i]${RST} $*"; }
sep()  { echo -e "${CYA}────────────────────────────────────────────────────${RST}"; }

# ── Détection sudo ────────────────────────────────────────────────────────────
if [[ "$(id -u)" -eq 0 ]]; then SUDO=""; else SUDO="sudo"; fi

# ── Chemins (substitués par setup à la copie) ─────────────────────────────────
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MACOS_VERSION="@@MACOS_VERSION@@"
VM_INSTALL="macos-${MACOS_VERSION}-install"
VM_NORMAL="macos-${MACOS_VERSION}"
XL_INSTALL="${DIR}/macos-install.xl"
XL_NORMAL="${DIR}/macos.xl"
OPENCORE_IMG="${DIR}/OpenCore.img"
MACOS_DISK="${DIR}/macos.qcow2"
RECOVERY_IMG="${DIR}/BaseSystem.img"
OCS_DIR="@@OCS_DIR@@"      # ~/opcore-simplify par défaut
VNC_PORT=5900
EFI_MNT="${DIR}/.efi_mnt"

# ── Helpers état domaine ───────────────────────────────────────────────────────
_domid() { $SUDO xl list 2>/dev/null | awk -v n="$1" '$1==n{print $2}'; }

_state() {
  local S; S=$($SUDO xl list 2>/dev/null | awk -v n="$1" '$1==n{print $5}')
  case "$S" in
    r*|b*) echo "running" ;;
    p*)    echo "paused"  ;;
    "")    echo "absent"  ;;
    *)     echo "$S"      ;;
  esac
}

# Purge un domaine zombie (connu dans xenstore mais processus mort)
_purge_zombie() {
  local NAME="$1"
  warn "Purge du domaine zombie '${NAME}'..."
  $SUDO xl destroy "${NAME}" 2>/dev/null || true
  sleep 1
  # Chercher dans xenstore par nom et supprimer
  local XS_DOMID
  XS_DOMID=$($SUDO xenstore-list /local/domain 2>/dev/null | while read -r D; do
    local N; N=$($SUDO xenstore-read "/local/domain/${D}/name" 2>/dev/null || true)
    [[ "${N}" == "${NAME}" ]] && echo "${D}" && break
  done || true)
  if [[ -n "${XS_DOMID}" ]]; then
    warn "Suppression xenstore domid ${XS_DOMID} (${NAME})..."
    $SUDO xenstore-rm "/local/domain/${XS_DOMID}" 2>/dev/null || true
    $SUDO xenstore-rm "/libxl/${XS_DOMID}"        2>/dev/null || true
  fi
  sleep 1
  if [[ -z "$(_domid "${NAME}")" ]]; then
    ok "Domaine zombie purgé."
  else
    err "Purge incomplète — essayez : sudo systemctl restart xenstored"
  fi
}

# ── Démarrage ─────────────────────────────────────────────────────────────────
_do_start() {
  local NAME="$1" XLCFG="$2"
  local STATE; STATE=$(_state "${NAME}")

  if [[ "${STATE}" == "running" ]]; then
    warn "La VM '${NAME}' tourne déjà (domid: $(_domid "${NAME}"))."
    info "VNC : vncviewer localhost:${VNC_PORT}"
    return 0
  fi

  [[ -f "${XLCFG}" ]] || { err "Config xl introuvable : ${XLCFG}"; exit 1; }

  # Purge zombie si le nom existe mais la VM n'est pas running
  local STALE; STALE=$(_domid "${NAME}")
  if [[ -n "${STALE}" && "${STATE}" != "running" ]]; then
    warn "Domaine zombie détecté (domid: ${STALE}) — purge..."
    _purge_zombie "${NAME}"
  fi

  info "Démarrage de '${NAME}'..."
  $SUDO xl create "${XLCFG}"
  sleep 2

  local DOMID; DOMID=$(_domid "${NAME}")
  if [[ -n "${DOMID}" ]]; then
    ok "VM démarrée (domid: ${DOMID})"
    info "VNC : vncviewer localhost:${VNC_PORT}  (ou ./vm.sh vnc)"
  else
    err "La VM n'apparaît pas dans xl list. Vérifiez : ./vm.sh log"
    exit 1
  fi
}

cmd_start()         { sep; _do_start "${VM_NORMAL}"  "${XL_NORMAL}";  }
cmd_start_install() { sep; info "Mode installation (Recovery monté)..."
                      _do_start "${VM_INSTALL}" "${XL_INSTALL}"; }

# ── Arrêt ─────────────────────────────────────────────────────────────────────
cmd_stop() {
  sep
  local NAME="${VM_NORMAL}"
  [[ "$(_state "${NAME}")" == "absent" ]] && NAME="${VM_INSTALL}"
  local STATE; STATE=$(_state "${NAME}")

  if [[ "${STATE}" == "absent" ]]; then
    warn "Aucune VM macOS active."; return 0
  fi
  info "Arrêt ACPI de '${NAME}' (max 40s)..."
  $SUDO xl shutdown "${NAME}"
  local I=0
  while [[ $(_state "${NAME}") != "absent" && $I -lt 40 ]]; do
    sleep 1; (( I++ )); printf '.'
  done; echo ""
  if [[ $(_state "${NAME}") == "absent" ]]; then
    ok "VM arrêtée."
  else
    warn "Timeout ACPI. Forcez avec : ./vm.sh kill"
  fi
}

cmd_kill() {
  sep
  local NAME="${VM_NORMAL}"
  [[ "$(_state "${NAME}")" == "absent" ]] && NAME="${VM_INSTALL}"

  if [[ "$(_state "${NAME}")" == "absent" ]]; then
    # Chercher quand même des zombies
    local FOUND=0
    for N in "${VM_NORMAL}" "${VM_INSTALL}"; do
      if [[ -n "$(_domid "${N}")" ]]; then
        warn "Zombie trouvé : ${N}"; _purge_zombie "${N}"; FOUND=1
      fi
    done
    [[ "${FOUND}" -eq 0 ]] && warn "Aucune VM macOS active."; return 0
  fi
  warn "Destruction forcée de '${NAME}'..."
  $SUDO xl destroy "${NAME}" 2>/dev/null || _purge_zombie "${NAME}"
  ok "VM détruite."
}

cmd_restart() {
  local NAME="${VM_NORMAL}"
  [[ "$(_state "${NAME}")" == "absent" ]] && NAME="${VM_INSTALL}"
  if [[ "$(_state "${NAME}")" == "absent" ]]; then
    warn "Aucune VM active — démarrage..."; cmd_start; return
  fi
  info "Redémarrage de '${NAME}'..."
  $SUDO xl reboot "${NAME}" && ok "Redémarrage envoyé."
}

cmd_pause() {
  local NAME="${VM_NORMAL}"
  [[ "$(_state "${NAME}")" == "absent" ]] && NAME="${VM_INSTALL}"
  $SUDO xl pause "${NAME}" && ok "VM suspendue."
}

cmd_resume() {
  local NAME="${VM_NORMAL}"
  [[ "$(_state "${NAME}")" != "paused" ]] && NAME="${VM_INSTALL}"
  $SUDO xl unpause "${NAME}" && ok "VM reprise."
}

cmd_status() {
  sep
  echo -e "${BLD}  État VM macOS ${MACOS_VERSION}${RST}"
  sep
  for NAME in "${VM_INSTALL}" "${VM_NORMAL}"; do
    local STATE; STATE=$(_state "${NAME}")
    local DOMID; DOMID=$(_domid "${NAME}")
    case "${STATE}" in
      running) echo -e "  ${GRN}●${RST} ${BLD}${NAME}${RST} — ${GRN}en cours${RST} (domid: ${DOMID})" ;;
      paused)  echo -e "  ${YEL}⏸${RST} ${BLD}${NAME}${RST} — ${YEL}suspendue${RST} (domid: ${DOMID})" ;;
      absent)  echo -e "  ${RED}○${RST} ${BLD}${NAME}${RST} — arrêtée" ;;
      *)       echo -e "  ${YEL}?${RST} ${BLD}${NAME}${RST} — ${STATE}" ;;
    esac
  done
  sep
  local FREE; FREE=$($SUDO xl info 2>/dev/null | awk '/^free_memory/{print $3}' || echo "?")
  info "Mémoire Xen libre : ${FREE} Mo"
  info "VNC : localhost:${VNC_PORT}"
  sep
}

cmd_list() { $SUDO xl list; }

cmd_vnc() {
  if command -v vncviewer &>/dev/null; then
    info "Connexion VNC sur localhost:${VNC_PORT}..."
    vncviewer "localhost:${VNC_PORT}"
  else
    warn "vncviewer introuvable — connexion manuelle : vncviewer localhost:${VNC_PORT}"
    info "Installation : sudo zypper install tigervnc"
  fi
}

cmd_console() {
  local NAME="${VM_NORMAL}"
  [[ "$(_state "${NAME}")" == "absent" ]] && NAME="${VM_INSTALL}"
  [[ "$(_state "${NAME}")" == "absent" ]] && { err "Aucune VM active."; exit 1; }
  info "Console série (Ctrl+] pour quitter)..."
  $SUDO xl console "${NAME}"
}

cmd_log() {
  sep; echo -e "${BLD}  Logs Xen/QEMU${RST}"; sep
  local QLOG; QLOG=$(ls -t /var/log/xen/qemu-dm-*.log 2>/dev/null | head -1 || true)
  if [[ -n "${QLOG}" ]]; then
    info "Log QEMU : ${QLOG}"; echo ""
    $SUDO tail -50 "${QLOG}"
  else
    warn "Aucun log QEMU dans /var/log/xen/"
    info "Log Xen kernel :"; $SUDO xl dmesg | tail -30
  fi
  sep
}

cmd_info() {
  local NAME="${VM_NORMAL}"
  [[ "$(_state "${NAME}")" == "absent" ]] && NAME="${VM_INSTALL}"
  local DOMID; DOMID=$(_domid "${NAME}")
  [[ -z "${DOMID}" ]] && { err "VM non active."; exit 1; }
  $SUDO xl dominfo "${NAME}"; sep; $SUDO xl vcpu-list "${NAME}"
}

# ── EFI : montage / démontage ─────────────────────────────────────────────────
_efi_loop_file="${DIR}/.efi_loop"

_efi_check_img() {
  [[ -f "${OPENCORE_IMG}" ]] || { err "OpenCore.img introuvable : ${OPENCORE_IMG}"; exit 1; }
}

cmd_efi_mount() {
  sep; info "Montage de la partition EFI..."
  _efi_check_img

  if mountpoint -q "${EFI_MNT}" 2>/dev/null; then
    warn "EFI déjà monté sur ${EFI_MNT}"; return 0
  fi
  mkdir -p "${EFI_MNT}"

  local LOOP; LOOP=$($SUDO losetup --find --partscan --show "${OPENCORE_IMG}")
  echo "${LOOP}" > "${_efi_loop_file}"
  sleep 1

  local PART="${LOOP}p1"
  [[ -e "${PART}" ]] || PART="${LOOP}p2"
  [[ -e "${PART}" ]] || { $SUDO losetup -d "${LOOP}"; err "Partition EFI introuvable."; exit 1; }

  $SUDO mount -t vfat "${PART}" "${EFI_MNT}" || {
    $SUDO losetup -d "${LOOP}"; err "Montage échoué."; exit 1
  }
  ok "EFI monté : ${EFI_MNT}  (loop: ${LOOP})"
  info "Contenu :"; $SUDO ls -lh "${EFI_MNT}/"
  sep
}

cmd_efi_umount() {
  sep; info "Démontage de la partition EFI..."
  if ! mountpoint -q "${EFI_MNT}" 2>/dev/null; then
    warn "EFI non monté."; return 0
  fi
  $SUDO umount "${EFI_MNT}"
  rmdir "${EFI_MNT}" 2>/dev/null || true
  if [[ -f "${_efi_loop_file}" ]]; then
    local LOOP; LOOP=$(cat "${_efi_loop_file}")
    $SUDO losetup -d "${LOOP}" 2>/dev/null && ok "Loop device détaché." || warn "Détachement loop échoué."
    rm -f "${_efi_loop_file}"
  fi
  ok "EFI démonté."; sep
}

# ── EFI : édition config.plist ────────────────────────────────────────────────
cmd_efi_edit() {
  sep; info "Édition de EFI/OC/config.plist..."
  cmd_efi_mount
  local PLIST="${EFI_MNT}/EFI/OC/config.plist"
  [[ -f "${PLIST}" ]] || { cmd_efi_umount; err "config.plist introuvable."; exit 1; }
  local EDITOR="${EDITOR:-nano}"
  command -v "${EDITOR}" &>/dev/null || EDITOR=vi
  info "Éditeur : ${EDITOR}"
  $SUDO "${EDITOR}" "${PLIST}"
  ok "config.plist sauvegardé."
  cmd_efi_umount
}

# ── EFI : sauvegarde / restauration ───────────────────────────────────────────
cmd_efi_backup() {
  sep
  local BACKUP="${DIR}/EFI-backup-$(date +%Y%m%d-%H%M%S).tar.gz"
  cmd_efi_mount
  $SUDO tar -czf "${BACKUP}" -C "${EFI_MNT}" . || { cmd_efi_umount; err "Sauvegarde échouée."; exit 1; }
  ok "Sauvegarde : ${BACKUP}"
  cmd_efi_umount; sep
}

cmd_efi_restore() {
  local BACKUP="${1:-}"
  [[ -f "${BACKUP}" ]] || { err "Fichier introuvable : ${BACKUP}"; exit 1; }
  sep; warn "Restauration EFI depuis ${BACKUP}..."
  cmd_efi_mount
  $SUDO rm -rf "${EFI_MNT:?}"/*
  $SUDO tar -xzf "${BACKUP}" -C "${EFI_MNT}" || { cmd_efi_umount; err "Restauration échouée."; exit 1; }
  ok "EFI restauré."
  cmd_efi_umount; sep
}

# ── EFI : copier un config.plist depuis Results OCS ───────────────────────────
cmd_efi_update_config() {
  local SRC="${1:-${OCS_DIR}/Results/EFI/OC/config.plist}"
  [[ -f "${SRC}" ]] || { err "config.plist source introuvable : ${SRC}"; exit 1; }
  sep; info "Mise à jour config.plist depuis : ${SRC}"
  cmd_efi_mount
  local PLIST="${EFI_MNT}/EFI/OC/config.plist"
  $SUDO cp "${SRC}" "${PLIST}"
  ok "config.plist mis à jour."
  # Afficher les paramètres clés
  info "Vérification :"
  for KEY in PickerMode SecureBootModel DisableSecurityPolicy LapicKernelPanic; do
    VAL=$(grep -A1 "<key>${KEY}</key>" "${PLIST}" | tail -1 | sed 's/.*<[^>]*>//;s/<.*//' | xargs || true)
    echo "    ${KEY} = ${VAL}"
  done
  cmd_efi_umount; sep
}

# ── OpenCore : basculer DEBUG ↔ RELEASE ──────────────────────────────────────
# Le mode DEBUG correspond à Target=67 dans config.plist (log sur écran+fichier)
# Le mode RELEASE correspond à Target=0 (pas de log → boot ~30-40s plus rapide)
cmd_oc_debug() {
  sep; info "Activation mode DEBUG OpenCore (verbose, logs, boot lent)..."
  cmd_efi_mount
  local PLIST="${EFI_MNT}/EFI/OC/config.plist"
  [[ -f "${PLIST}" ]] || { cmd_efi_umount; err "config.plist introuvable."; exit 1; }
  # Activer debug logs
  $SUDO python3 - "${PLIST}" <<'PYEOF'
import sys, plistlib, pathlib
p = pathlib.Path(sys.argv[1])
pl = plistlib.loads(p.read_bytes())
pl["Misc"]["Debug"]["AppleDebug"]    = True
pl["Misc"]["Debug"]["ApplePanic"]    = True
pl["Misc"]["Debug"]["DisableWatchDog"] = True
pl["Misc"]["Debug"]["Target"]        = 67   # log écran + fichier
pl["Misc"]["Boot"]["Timeout"]        = 10   # picker visible plus longtemps
p.write_bytes(plistlib.dumps(pl, fmt=plistlib.FMT_XML, sort_keys=False))
print("DEBUG activé : Target=67, AppleDebug=true, ApplePanic=true")
PYEOF
  ok "Mode DEBUG activé — redémarrez la VM."
  cmd_efi_umount; sep
}

cmd_oc_release() {
  sep; info "Activation mode RELEASE OpenCore (silencieux, boot rapide)..."
  cmd_efi_mount
  local PLIST="${EFI_MNT}/EFI/OC/config.plist"
  [[ -f "${PLIST}" ]] || { cmd_efi_umount; err "config.plist introuvable."; exit 1; }
  $SUDO python3 - "${PLIST}" <<'PYEOF'
import sys, plistlib, pathlib
p = pathlib.Path(sys.argv[1])
pl = plistlib.loads(p.read_bytes())
pl["Misc"]["Debug"]["AppleDebug"]    = False
pl["Misc"]["Debug"]["ApplePanic"]    = False
pl["Misc"]["Debug"]["DisableWatchDog"] = True
pl["Misc"]["Debug"]["Target"]        = 0    # aucun log → boot rapide
pl["Misc"]["Boot"]["Timeout"]        = 5
p.write_bytes(plistlib.dumps(pl, fmt=plistlib.FMT_XML, sort_keys=False))
print("RELEASE activé : Target=0, logs désactivés")
PYEOF
  ok "Mode RELEASE activé — redémarrez la VM pour un boot rapide."
  cmd_efi_umount; sep
}

cmd_oc_status() {
  sep; info "Statut OpenCore (config.plist actuel)..."
  _efi_check_img
  local ALREADY_MOUNTED=0
  mountpoint -q "${EFI_MNT}" 2>/dev/null && ALREADY_MOUNTED=1
  [[ "${ALREADY_MOUNTED}" -eq 0 ]] && cmd_efi_mount

  local PLIST="${EFI_MNT}/EFI/OC/config.plist"
  if [[ -f "${PLIST}" ]]; then
    $SUDO python3 - "${PLIST}" <<'PYEOF'
import sys, plistlib, pathlib
p = pathlib.Path(sys.argv[1])
pl = plistlib.loads(p.read_bytes())
d = pl.get("Misc", {}).get("Debug", {})
s = pl.get("Misc", {}).get("Security", {})
b = pl.get("Misc", {}).get("Boot", {})
k = pl.get("Kernel", {}).get("Quirks", {})
u = pl.get("UEFI", {}).get("Quirks", {})
target = d.get("Target", "?")
mode = "DEBUG" if int(target) >= 1 else "RELEASE"
print(f"\n  Mode OpenCore     : {mode} (Target={target})")
print(f"  AppleDebug        : {d.get('AppleDebug','?')}")
print(f"  ApplePanic        : {d.get('ApplePanic','?')}")
print(f"  PickerMode        : {b.get('PickerMode','?')}")
print(f"  SecureBootModel   : {s.get('SecureBootModel','?')}")
print(f"  LapicKernelPanic  : {k.get('LapicKernelPanic','?')}")
print(f"  DisableSecPolicy  : {u.get('DisableSecurityPolicy','?')}")
print(f"  Timeout           : {b.get('Timeout','?')}s\n")
PYEOF
  fi
  [[ "${ALREADY_MOUNTED}" -eq 0 ]] && cmd_efi_umount
  sep
}

# ── Usage ─────────────────────────────────────────────────────────────────────
usage() {
  sep
  echo -e "${BLD}  vm.sh — VM macOS ${MACOS_VERSION} (Xen HVM)${RST}"
  sep
  cat <<EOF

${BLD}Contrôle VM :${RST}
  start              Démarrer la VM (mode normal)
  start-install      Démarrer en mode installation (Recovery monté)
  stop               Arrêt propre (ACPI, attend 40s)
  kill               Forcer l'arrêt immédiat (xl destroy)
  restart            Redémarrer la VM
  pause              Suspendre la VM
  resume             Reprendre la VM
  status             État des domaines (running/paused/absent)
  list               Lister toutes les VMs Xen actives

${BLD}Affichage & Logs :${RST}
  vnc                Ouvrir vncviewer sur localhost:${VNC_PORT}
  console            Console série xl (Ctrl+] pour quitter)
  log                Afficher les logs QEMU/Xen récents
  info               Infos détaillées (dominfo + vcpu-list)

${BLD}Partition EFI :${RST}
  efi-mount          Monter OpenCore.img sur ${EFI_MNT}
  efi-umount         Démonter la partition EFI
  efi-edit           Éditer EFI/OC/config.plist (nano/vi)
  efi-backup         Sauvegarder l'EFI en tar.gz horodaté
  efi-restore FILE   Restaurer l'EFI depuis une sauvegarde
  efi-update [FILE]  Copier un config.plist depuis OCS Results/
                     (défaut : ${OCS_DIR}/Results/EFI/OC/config.plist)

${BLD}OpenCore DEBUG / RELEASE :${RST}
  oc-debug           Activer le mode DEBUG (Target=67, logs, boot lent)
  oc-release         Activer le mode RELEASE (Target=0, boot rapide)
  oc-status          Afficher le mode actuel et les paramètres clés

${BLD}Exemples :${RST}
  ./vm.sh start-install          # 1er démarrage pour installer macOS
  ./vm.sh vnc                    # Se connecter à l'écran
  ./vm.sh oc-release             # Désactiver les logs → boot rapide
  ./vm.sh efi-edit               # Modifier config.plist directement
  ./vm.sh efi-update             # Appliquer le config.plist d'OCS
  ./vm.sh efi-backup             # Sauvegarder avant une modif
  ./vm.sh kill                   # Forcer l'arrêt (zombie inclus)

EOF
  sep
}

# ── Dispatch ──────────────────────────────────────────────────────────────────
CMD="${1:-help}"; shift || true
case "${CMD}" in
  start)          cmd_start ;;
  start-install)  cmd_start_install ;;
  stop)           cmd_stop ;;
  kill)           cmd_kill ;;
  restart)        cmd_restart ;;
  pause)          cmd_pause ;;
  resume)         cmd_resume ;;
  status)         cmd_status ;;
  list)           cmd_list ;;
  vnc)            cmd_vnc ;;
  console)        cmd_console ;;
  log)            cmd_log ;;
  info)           cmd_info ;;
  efi-mount)      cmd_efi_mount ;;
  efi-umount)     cmd_efi_umount ;;
  efi-edit)       cmd_efi_edit ;;
  efi-backup)     cmd_efi_backup ;;
  efi-restore)    cmd_efi_restore "${1:-}" ;;
  efi-update)     cmd_efi_update_config "${1:-}" ;;
  oc-debug)       cmd_oc_debug ;;
  oc-release)     cmd_oc_release ;;
  oc-status)      cmd_oc_status ;;
  help|--help|-h) usage ;;
  *) err "Commande inconnue : '${CMD}'"; usage; exit 1 ;;
esac
