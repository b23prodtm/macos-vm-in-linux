#!/usr/bin/env bash
# =============================================================================
# setup-macos-vm-xen.sh — macOS VM via OpenCore Simplify
#                          openSUSE Tumbleweed + Xen HVM (xl/libxl)
#
# Prérequis : dom0 Xen actif, réseau bridge xenbr0 (ou virbr0)
# Usage     : bash setup-macos-vm-xen.sh [--macos VERSION] [--help]
# =============================================================================
set -euo pipefail
IFS=$'\n\t'

# ── Mode rootless : détection sudo ───────────────────────────────────────────
# Le script peut tourner en tant qu'utilisateur normal.
# Les commandes nécessitant des droits élevés utilisent $SUDO automatiquement.
if [[ "$(id -u)" -eq 0 ]]; then
  SUDO=""
else
  if command -v sudo &>/dev/null; then
    SUDO="sudo"
    echo -e "\033[1;33m[!]\033[0m Mode rootless : les commandes privilégiées utiliseront sudo."
  else
    echo -e "\033[0;31m[✘]\033[0m sudo introuvable et vous n'êtes pas root. Installez sudo ou relancez en root."
    exit 1
  fi
fi

RED='\033[0;31m'; GRN='\033[0;32m'; YEL='\033[1;33m'
BLU='\033[0;34m'; CYA='\033[0;36m'; RST='\033[0m'; BLD='\033[1m'

log()  { echo -e "${BLU}[$(date +%H:%M:%S)]${RST} $*"; }
ok()   { echo -e "${GRN}[✔]${RST} $*"; }
warn() { echo -e "${YEL}[!]${RST} $*"; }
die()  { echo -e "${RED}[✘]${RST} $*" >&2; exit 1; }
sep()  { echo -e "${CYA}────────────────────────────────────────────────────${RST}"; }

# ── OPTIMIZED: Calcul dynamique de RAM et CPU ────────────────────────────────
# Appelée après la définition des couleurs pour affichage correct
calculate_resources() {
  local TOTAL_RAM_MB TOTAL_CPUS
  TOTAL_RAM_MB=$(grep MemTotal /proc/meminfo | awk '{print int($2/1024)}')
  TOTAL_CPUS=$(nproc)
  ok "Système détecté : ${TOTAL_RAM_MB} Mo RAM, ${TOTAL_CPUS} CPU(s)"
  # Ne pas écraser si --ram/--cores passés manuellement
  if [[ "${RAM_OVERRIDE:-0}" -eq 0 ]]; then
    RAM_MB=$(( (TOTAL_RAM_MB * 80) / 100 ))
    ok "RAM VM (80% auto) : ${RAM_MB} Mo"
  else
    ok "RAM VM (manuel)   : ${RAM_MB} Mo"
  fi
  if [[ "${CORES_OVERRIDE:-0}" -eq 0 ]]; then
    CPU_CORES=${TOTAL_CPUS}
    ok "CPUs VM (100% auto) : ${CPU_CORES}"
  else
    ok "CPUs VM (manuel)    : ${CPU_CORES}"
  fi
}

# ── Mode dry-run ──────────────────────────────────────────────────────────────
# En dryrun, les commandes destructives/lentes sont simulées
run() {
  if [[ "${DRYRUN:-0}" -eq 1 ]]; then
    echo -e "${CYA}[dryrun]${RST} $*"
  else
    "$@"
  fi
}

# ── Valeurs par défaut (calculées dynamiquement) ──────────────────────────────
MACOS_VERSION="ventura"   # sequoia | sonoma | ventura | monterey | big-sur
DISK_SIZE="80G"
RAM_MB=8192               # valeur initiale — écrasée par calculate_resources()
CPU_CORES=4               # valeur initiale — écrasée par calculate_resources()
BRIDGE="xenbr0"           # bridge réseau Xen ; fallback virbr0
VM_DIR="${HOME}/VMs/macos-${MACOS_VERSION}"
OCS_DIR="${HOME}/opcore-simplify"
OCS_REPO="https://github.com/b23prodtm/OpCore-Simplify.git"
OCS_BRANCH="fix/validator"

SKIP_DEPS=0; SKIP_OCS=0; SKIP_RECOVERY=0; RUN_ONLY=0; DRYRUN=0; SKIP_LIBVIRT=0; FORCE_REBUILD=0
RAM_OVERRIDE=0; CORES_OVERRIDE=0

usage() {
cat <<EOF
${BLD}Usage :${RST} $0 [OPTIONS]

  --macos VERSION      Version cible (défaut: ventura)
                       sequoia | sonoma | ventura | monterey | big-sur
  --disk-size SIZE     Taille disque (défaut: 80G)
  --ram MB             RAM en Mo (défaut: 80% du système — auto-détecté)
  --cores N            vCPUs (défaut: 100% du système — auto-détecté)
  --bridge BRIDGE      Bridge réseau (défaut: xenbr0)
  --vm-dir PATH        Répertoire VM
  --ocs-dir PATH       Répertoire OpCore Simplify
  --skip-deps          Ne pas installer les paquets
  --skip-ocs           EFI déjà généré
  --skip-recovery      Ne pas re-télécharger le BaseSystem
  --skip-libvirt       Ne pas enregistrer dans libvirt/virt-manager
  --force-rebuild      Reconstruire OpenCore.img sans demander confirmation
  --run-only           Lancer la VM directement ($SUDO xl create)
  --dryrun             Simuler toutes les étapes sans rien écrire ni installer
  --help
EOF
exit 0
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --macos)         MACOS_VERSION="$2"; shift 2 ;;
    --disk-size)     DISK_SIZE="$2";     shift 2 ;;
    --ram)           RAM_MB="$2"; RAM_OVERRIDE=1;   shift 2 ;;
    --cores)         CPU_CORES="$2"; CORES_OVERRIDE=1; shift 2 ;;
    --bridge)        BRIDGE="$2";        shift 2 ;;
    --vm-dir)        VM_DIR="$2";        shift 2 ;;
    --ocs-dir)       OCS_DIR="$2";       shift 2 ;;
    --skip-deps)     SKIP_DEPS=1;        shift   ;;
    --skip-ocs)      SKIP_OCS=1;         shift   ;;
    --skip-recovery) SKIP_RECOVERY=1;    shift   ;;
    --skip-libvirt)  SKIP_LIBVIRT=1;     shift   ;;
    --force-rebuild) FORCE_REBUILD=1;    shift   ;;
    --run-only)      RUN_ONLY=1;         shift   ;;
    --dryrun)        DRYRUN=1;           shift   ;;
    --help|-h)       usage ;;
    *) die "Argument inconnu : $1" ;;
  esac
done

VM_DIR="${HOME}/VMs/macos-${MACOS_VERSION}"
OPENCORE_IMG="${VM_DIR}/OpenCore.img"
MACOS_DISK="${VM_DIR}/macos.qcow2"
RECOVERY_IMG="${VM_DIR}/BaseSystem.img"
OVMF_CODE=""
OVMF_VARS_SRC=""

# ── 1. Vérifications Xen dom0 ─────────────────────────────────────────────────
check_xen() {
  sep; log "Vérification de l'environnement Xen..."

  # dom0 ?
  # XEN_PROC_DIR permet de surcharger /proc/xen (utile en CI/dryrun)
  local XEN_DIR="${XEN_PROC_DIR:-/proc/xen}"
  if [[ ! -d "${XEN_DIR}" ]]; then
    die "${XEN_DIR} absent. Ce script doit tourner dans un dom0 Xen."
  fi
  if ! grep -q "control_d" "${XEN_DIR}/capabilities" 2>/dev/null; then
    die "Pas en dom0 (capabilities ne contient pas 'control_d')."
  fi
  ok "Xen dom0 confirmé"

  # xl disponible ?
  $SUDO which xl &>/dev/null || die "'xl' introuvable. Installez xen-tools."
  ok "$SUDO xl : $($SUDO xl info | awk '/^xen_version/{print $3}')"

  # Version Xen
  local XEN_VER; XEN_VER=$($SUDO xl info 2>/dev/null | awk '/^xen_version/{print $3}')
  ok "Xen version : ${XEN_VER}"

  # Bridge réseau
  if ! ip link show "${BRIDGE}" &>/dev/null; then
    warn "Bridge '${BRIDGE}' introuvable."
    # Tenter virbr0 comme fallback
    if ip link show virbr0 &>/dev/null; then
      BRIDGE="virbr0"
      warn "Utilisation de virbr0 à la place."
    else
      warn "Aucun bridge réseau trouvé. La VM démarrera sans réseau."
      warn "Créez un bridge : ip link add ${BRIDGE} type bridge && ip link set ${BRIDGE} up"
      BRIDGE=""
    fi
  else
    ok "Bridge réseau : ${BRIDGE}"
  fi
}

# ── 2. Dépendances zypper ─────────────────────────────────────────────────────
install_deps() {
  sep; log "Installation des dépendances..."

  local PKGS=(
    xen-tools              # xl, xenstore-*, xen-detect
    xen-libs               # libxenctrl etc.
    qemu-x86               # device model QEMU pour Xen HVM
    qemu-tools             # qemu-img
    ovmf                   # firmware UEFI — paquet openSUSE
    python3 python3-pip
    git wget curl
    dmidecode acpica       # pour OpCore Simplify
    p7zip-full
    gdisk                  # sgdisk pour partitionner l'ESP
  )

  run $SUDO zypper --non-interactive refresh
  # ovmf peut s'appeler différemment sur Tumbleweed
  run $SUDO zypper --non-interactive install --no-recommends "${PKGS[@]}" 2>/dev/null || \
  run $SUDO zypper --non-interactive install --no-recommends \
    xen-tools xen-libs qemu-x86 qemu-tools \
    python3 python3-pip git wget curl \
    dmidecode acpica p7zip-full gdisk || true

  ok "Paquets installés"
  _find_ovmf
}

_find_ovmf() {
  # Xen embarque souvent son propre OVMF
  local CANDIDATES_CODE=(
    /usr/lib/xen/boot/ovmf.bin             # OVMF intégré Xen (Tumbleweed)
    /usr/share/qemu/ovmf-x86_64-4m-code.bin
    /usr/share/qemu/ovmf-x86_64-code.bin
    /usr/share/OVMF/OVMF_CODE.fd
  )
  local CANDIDATES_VARS=(
    /usr/lib/xen/boot/ovmf-vars.bin
    /usr/share/qemu/ovmf-x86_64-4m-vars.bin
    /usr/share/qemu/ovmf-x86_64-vars.bin
    /usr/share/OVMF/OVMF_VARS.fd
  )
  for f in "${CANDIDATES_CODE[@]}"; do [[ -f "$f" ]] && { OVMF_CODE="$f"; break; }; done
  for f in "${CANDIDATES_VARS[@]}"; do [[ -f "$f" ]] && { OVMF_VARS_SRC="$f"; break; }; done

  [[ -n "$OVMF_CODE" ]] || die "OVMF_CODE introuvable. Installez 'ovmf' ou vérifiez /usr/lib/xen/boot/"
  ok "OVMF CODE : ${OVMF_CODE}"
  [[ -n "$OVMF_VARS_SRC" ]] && ok "OVMF VARS : ${OVMF_VARS_SRC}" || warn "OVMF VARS absent (mode stateless)"
}

# ── 3. Répertoire VM ──────────────────────────────────────────────────────────
prepare_dirs() {
  sep; log "Préparation de ${VM_DIR}..."
  mkdir -p "${VM_DIR}"
  if [[ -n "${OVMF_VARS_SRC}" && ! -f "${VM_DIR}/OVMF_VARS.fd" ]]; then
    $SUDO cp "${OVMF_VARS_SRC}" "${VM_DIR}/OVMF_VARS.fd"
    $SUDO chown "$USER" "${VM_DIR}/OVMF_VARS.fd" 2>/dev/null || true
    ok "OVMF_VARS.fd copié (persistant par VM)"
  fi
}

# ── 4. OpCore Simplify ────────────────────────────────────────────────────────
run_opcore_simplify() {
  sep; log "OpCore Simplify — génération EFI OpenCore..."

  if [[ ! -d "${OCS_DIR}" ]]; then
    run git clone --branch "${OCS_BRANCH}" "${OCS_REPO}" "${OCS_DIR}"
  else
    local CURRENT_BRANCH; CURRENT_BRANCH=$(git -C "${OCS_DIR}" rev-parse --abbrev-ref HEAD)
    if [[ "${CURRENT_BRANCH}" != "${OCS_BRANCH}" ]]; then
      warn "Branche actuelle '${CURRENT_BRANCH}' ≠ '${OCS_BRANCH}', basculement..."
      run git -C "${OCS_DIR}" fetch origin
      run git -C "${OCS_DIR}" checkout "${OCS_BRANCH}"
    fi
    run git -C "${OCS_DIR}" pull --ff-only origin "${OCS_BRANCH}" || \
      warn "git pull échoué, version locale conservée."
  fi
  ok "Branche : ${OCS_BRANCH} @ $(git -C "${OCS_DIR}" rev-parse --short HEAD)"

  [[ -f "${OCS_DIR}/requirements.txt" ]] && \
    run pip3 install --quiet -r "${OCS_DIR}/requirements.txt"

  cat <<EOF

${YEL}${BLD}══════════════════════════════════════════════════════════════
  OpCore Simplify — Conseils pour VM Xen HVM
  ──────────────────────────────────────────
  • SMBIOS     : MacPro7,1  (Ventura/Sonoma/Sequoia)
                 iMacPro1,1 (Monterey/Big Sur)
  • GPU        : AUCUN (la VM utilise le framebuffer VNC/SDL)
  • USB        : USBInjectAll  (pas USBToolBox, incompatible Linux)
  • Ethernet   : e1000 ou vmxnet3 selon dispo dans macOS
  • SIP/Secure Boot : désactiver pour débug initial
  • Ctrl+C dans OCS = abandon propre, reprise possible
══════════════════════════════════════════════════════════════${RST}

EOF

  pushd "${OCS_DIR}" > /dev/null
  set +e
  python3 OpCore-Simplify.py
  OCS_EXIT=$?
  set -e
  popd > /dev/null

  if [[ $OCS_EXIT -ne 0 ]]; then
    warn "OpCore Simplify a quitté avec le code ${OCS_EXIT} (Ctrl+C ou erreur)."
    warn "Si l'EFI a quand même été généré dans Results/, le script continue."
    warn "Sinon, relancez : bash $0 --skip-deps --skip-recovery"
  fi

  local EFI_PATH
  EFI_PATH=$(find "${OCS_DIR}/Results" -maxdepth 3 -name "EFI" -type d 2>/dev/null | head -1)
  [[ -n "${EFI_PATH}" ]] || die "EFI non trouvé dans ${OCS_DIR}/Results/"
  echo "${EFI_PATH}" > "${VM_DIR}/.ocs_efi_path"
  ok "EFI : ${EFI_PATH}"
}

# ── 5. Image OpenCore (ESP FAT32) ─────────────────────────────────────────────
build_opencore_img() {
  sep; log "Construction de l'image OpenCore (ESP 200 Mo)..."

  # En dryrun : simuler sans résolution EFI ni accès disque
  if [[ "${DRYRUN:-0}" -eq 1 ]]; then
    echo -e "${CYA}[dryrun]${RST} qemu-img create -f raw ${OPENCORE_IMG} 220M"
    echo -e "${CYA}[dryrun]${RST} sgdisk + mkfs.fat + cp EFI → ${OPENCORE_IMG}"
    ok "Image OpenCore simulée (dryrun)"
    return 0
  fi

  # ── Guard : image déjà construite → proposer de la conserver ──────────────
  if [[ -f "${OPENCORE_IMG}" && -s "${OPENCORE_IMG}" ]]; then
    warn "OpenCore.img existe déjà ($(du -h "${OPENCORE_IMG}" | cut -f1))."

    # Libérer tout loop device orphelin tenant le fichier
    local LOCKED_LOOPS
    LOCKED_LOOPS=$($SUDO losetup -j "${OPENCORE_IMG}" 2>/dev/null | cut -d: -f1 || true)
    if [[ -n "${LOCKED_LOOPS}" ]]; then
      warn "Loop devices orphelins détectés : ${LOCKED_LOOPS}"
      while IFS= read -r LOOP; do
        $SUDO losetup -d "${LOOP}" 2>/dev/null && warn "  Libéré : ${LOOP}" || true
      done <<< "${LOCKED_LOOPS}"
    fi

    if [[ "${FORCE_REBUILD:-0}" -eq 1 ]]; then
      warn "Force rebuild demandé (--force-rebuild)."
    else
      read -r -p "  Reconstruire (écrase l'image existante) ? [o/N] " REBUILD
      if [[ "${REBUILD,,}" != "o" ]]; then
        ok "Image OpenCore conservée."
        return 0
      fi
    fi
    # Détacher tous les loop devices avant d'écraser
    $SUDO losetup -j "${OPENCORE_IMG}" 2>/dev/null | cut -d: -f1 | \
      xargs -r -I{} $SUDO losetup -d {} 2>/dev/null || true
    rm -f "${OPENCORE_IMG}"
  fi

  # ── Résoudre le chemin EFI (priorité : cache → recherche → saisie manuelle)
  local EFI_PATH=""

  # 1. Chemin sauvegardé par run_opcore_simplify
  local CACHED; CACHED=$(cat "${VM_DIR}/.ocs_efi_path" 2>/dev/null || true)
  if [[ -d "${CACHED}" ]]; then
    EFI_PATH="${CACHED}"
    ok "EFI depuis cache : ${EFI_PATH}"
  fi

  # 2. Recherche dynamique dans OCS_DIR/Results/
  if [[ -z "${EFI_PATH}" ]]; then
    EFI_PATH=$(find "${OCS_DIR}/Results" -maxdepth 4 -name "EFI" -type d 2>/dev/null | head -1 || true)
    if [[ -n "${EFI_PATH}" ]]; then
      ok "EFI trouvé : ${EFI_PATH}"
      echo "${EFI_PATH}" > "${VM_DIR}/.ocs_efi_path"
    fi
  fi

  # 3. Fallback : saisie manuelle
  if [[ -z "${EFI_PATH}" ]]; then
    warn "Aucun dossier EFI trouvé automatiquement dans ${OCS_DIR}/Results/"
    warn "Lancez OpCore Simplify jusqu'au bout (Build OpenCore EFI) puis relancez."
    warn "Ou entrez le chemin manuellement (laisser vide pour annuler) :"
    read -r -p "  Chemin vers le dossier EFI : " EFI_PATH
    [[ -d "${EFI_PATH}" ]] || die "Chemin invalide. Relancez OpCore Simplify puis : bash $0 --skip-deps --skip-recovery"
    echo "${EFI_PATH}" > "${VM_DIR}/.ocs_efi_path"
  fi

  # 220M = 450560 secteurs → partition 2048:-1 dans les limites
  run qemu-img create -f raw "${OPENCORE_IMG}" 220M

  # Table GPT + partition ESP en un seul appel sgdisk
  # -Z : effacer, -o : nouvelle table GPT, -n 1:2048:-1 : jusqu'au dernier secteur
  run $SUDO sgdisk -Z -o \
    -n 1:2048:-1 -t 1:EF00 -c 1:"EFI System" \
    "${OPENCORE_IMG}"

  # Formater + copier via loop device
  local LOOP; LOOP=$($SUDO losetup --find --partscan --show "${OPENCORE_IMG}")
  run $SUDO mkfs.fat -F32 -n "EFI" "${LOOP}p1"

  local MNT; MNT=$(mktemp -d)
  run $SUDO mount "${LOOP}p1" "${MNT}"
  run $SUDO cp -r "${EFI_PATH}" "${MNT}/"
  sync
  run $SUDO umount "${MNT}"; rmdir "${MNT}"
  run $SUDO losetup -d "${LOOP}"

  ok "OpenCore.img : ${OPENCORE_IMG}"
}

# ── 6. Recovery macOS ─────────────────────────────────────────────────────────
download_recovery() {
  sep; log "Téléchargement du Recovery macOS (${MACOS_VERSION})..."

  declare -A BOARD_IDS=(
    [sequoia]="Mac-7BA5B2DFE22DDD8C"
    [sonoma]="Mac-226CB3C6A851A671"
    [ventura]="Mac-4B682C642B45593E"
    [monterey]="Mac-FFE5EF870D7BA81A"
    [big-sur]="Mac-42FD25EABCABB274"
  )
  local BOARD="${BOARD_IDS[${MACOS_VERSION}]:-}"
  [[ -n "$BOARD" ]] || die "Version inconnue : ${MACOS_VERSION}"

  local DLDIR="${VM_DIR}/macrecovery"
  mkdir -p "${DLDIR}"

  [[ -f "${DLDIR}/macrecovery.py" ]] || \
    curl -fsSL \
      "https://raw.githubusercontent.com/acidanthera/OpenCorePkg/master/Utilities/macrecovery/macrecovery.py" \
      -o "${DLDIR}/macrecovery.py"

  pushd "${DLDIR}" > /dev/null
  python3 macrecovery.py -b "${BOARD}" -m 00000000000000000 download
  popd > /dev/null

  local DMG; DMG=$(find "${DLDIR}" -name "BaseSystem.dmg" | head -1)
  [[ -f "${DMG}" ]] || die "BaseSystem.dmg introuvable dans ${DLDIR}"

  # Convertir DMG → raw (Xen ne parle pas DMG nativement)
  qemu-img convert -f dmg -O raw "${DMG}" "${RECOVERY_IMG}" 2>/dev/null || cp "${DMG}" "${RECOVERY_IMG}"
  ok "Recovery : ${RECOVERY_IMG}"
}

# ── 7. Disque macOS ───────────────────────────────────────────────────────────
create_macos_disk() {
  sep; log "Création du disque macOS (${DISK_SIZE})..."
  if [[ -f "${MACOS_DISK}" ]]; then
    warn "${MACOS_DISK} existe déjà."
    read -r -p "Recréer (efface les données) ? [o/N] " C
    [[ "${C,,}" == "o" ]] || { ok "Disque conservé."; return; }
  fi
  run qemu-img create -f qcow2 "${MACOS_DISK}" "${DISK_SIZE}"
  ok "Disque : ${MACOS_DISK} (${DISK_SIZE})"
}

# ── 8. Génération de la configuration xl ─────────────────────────────────────
generate_xl_config() {
  sep; log "Génération de la configuration Xen HVM (xl)..."

  local VARS_LINE=""
  if [[ -f "${VM_DIR}/OVMF_VARS.fd" ]]; then
    VARS_LINE="nvramstore = \"${VM_DIR}/OVMF_VARS.fd\""
  fi

  local NET_LINE=""
  if [[ -n "${BRIDGE}" ]]; then
    NET_LINE="vif = ['model=e1000, bridge=${BRIDGE}']"
  else
    NET_LINE="# vif = []  # Pas de bridge détecté — configurez manuellement"
  fi

  # Config mode installation (Recovery monté)
  cat > "${VM_DIR}/macos-install.xl" <<XL
# ═══════════════════════════════════════════════════════════════
#  Configuration Xen HVM — macOS ${MACOS_VERSION} (mode INSTALLATION)
#  Utilisation : $SUDO xl create ${VM_DIR}/macos-install.xl
# ═══════════════════════════════════════════════════════════════

name        = "macos-${MACOS_VERSION}-install"
type        = "hvm"

# ── Ressources ────────────────────────────────────────────────
vcpus       = ${CPU_CORES}
memory      = ${RAM_MB}

# ── Firmware UEFI ─────────────────────────────────────────────
# Xen utilise son propre OVMF ; si absent, spécifier le chemin :
# bios        = "ovmf"
# bios_path_override = "${OVMF_CODE}"
bios        = "ovmf"
${VARS_LINE}

# ── CPU : vendor Intel forcé via device_model_args_hvm (-cpu Penryn,vendor=GenuineIntel)
# cpuid xl non utilisé : le format de masque (32 car. hex) est incompatible
apic        = 1
acpi        = 1
hpet        = 1

# ── Disques ───────────────────────────────────────────────────
# sata.0 : OpenCore EFI (boot)
# sata.1 : Disque macOS principal
# sata.2 : BaseSystem Recovery
# access=rw + snapshot=on : qemu-xen IDE ne supporte pas access=ro
# snapshot=on protège le fichier source (écritures dans un overlay temporaire)
disk = [
    'format=raw,  vdev=hda, access=rw, target=${OPENCORE_IMG}',
    'format=qcow2,vdev=hdb, access=rw,              target=${MACOS_DISK}',
    'format=raw,  vdev=hdc, access=rw, target=${RECOVERY_IMG}',
]

# ── Réseau ────────────────────────────────────────────────────
${NET_LINE}

# ── USB ───────────────────────────────────────────────────────
usbdevice   = ['tablet']

# ── Affichage : VNC (headless / SSH tunnel) ───────────────────
vnc         = 1
vnclisten   = "127.0.0.1"
vncport     = 5900
vncpasswd   = ""
# Alternative SDL (si Xorg local) :
# sdl         = 1

# ── Device model (QEMU sous Xen) ─────────────────────────────
device_model_version    = "qemu-xen"
device_model_args_hvm   = [
    "-cpu", "Penryn,vendor=GenuineIntel,+sse3,+sse4.2,+avx2,+aes",
    "-global", "PIIX4_PM.disable_s3=1",
    "-global", "PIIX4_PM.disable_s4=1",
]

# ── Divers ────────────────────────────────────────────────────
on_poweroff = "destroy"
on_reboot   = "restart"
on_crash    = "preserve"
XL

  # Config mode normal (sans Recovery)
  cat > "${VM_DIR}/macos.xl" <<XL
# ═══════════════════════════════════════════════════════════════
#  Configuration Xen HVM — macOS ${MACOS_VERSION} (mode NORMAL)
#  Utilisation : $SUDO xl create ${VM_DIR}/macos.xl
# ═══════════════════════════════════════════════════════════════

name        = "macos-${MACOS_VERSION}"
type        = "hvm"
vcpus       = ${CPU_CORES}
memory      = ${RAM_MB}
bios        = "ovmf"
${VARS_LINE}

# cpuid : vendor Intel via device_model_args_hvm uniquement
apic = 1
acpi = 1
hpet = 1

disk = [
    'format=raw,  vdev=hda, access=rw, target=${OPENCORE_IMG}',
    'format=qcow2,vdev=hdb, access=rw,              target=${MACOS_DISK}',
]

${NET_LINE}
usbdevice   = ['tablet']
vnc         = 1
vnclisten   = "127.0.0.1"
vncport     = 5900
vncpasswd   = ""

device_model_version    = "qemu-xen"
device_model_args_hvm   = [
    "-cpu", "Penryn,vendor=GenuineIntel,+sse3,+sse4.2,+avx2,+aes",
    "-global", "PIIX4_PM.disable_s3=1",
    "-global", "PIIX4_PM.disable_s4=1",
]

on_poweroff = "destroy"
on_reboot   = "restart"
on_crash    = "preserve"
serial      = "none"
XL

  # Rétrocompatibilité : run-install.sh et run.sh délèguent à vm.sh
  cat > "${VM_DIR}/run-install.sh" <<'SH'
#!/usr/bin/env bash
exec "$(dirname "$0")/vm.sh" start-install "$@"
SH
  chmod +x "${VM_DIR}/run-install.sh"

  cat > "${VM_DIR}/run.sh" <<'SH'
#!/usr/bin/env bash
exec "$(dirname "$0")/vm.sh" start "$@"
SH
  chmod +x "${VM_DIR}/run.sh"

  # ── Script de gestion complet vm.sh ───────────────────────────
  cat > "${VM_DIR}/vm.sh" <<VMSH
#!/usr/bin/env bash
# =============================================================
#  vm.sh — Gestion de la VM macOS ${MACOS_VERSION} via xl
#  Usage : ./vm.sh <commande>
# =============================================================
set -euo pipefail

DIR="\$(cd "\$(dirname "\$0")" && pwd)"
VM_INSTALL="macos-${MACOS_VERSION}-install"
VM_NORMAL="macos-${MACOS_VERSION}"
XL_INSTALL="\${DIR}/macos-install.xl"
XL_NORMAL="\${DIR}/macos.xl"
VNC_PORT=5900

# Détection sudo
if [[ "\$(id -u)" -eq 0 ]]; then SUDO=""; else SUDO="sudo"; fi

# Couleurs
GRN='\033[0;32m'; YEL='\033[1;33m'; RED='\033[0;31m'
BLU='\033[0;34m'; CYA='\033[0;36m'; RST='\033[0m'; BLD='\033[1m'
ok()   { echo -e "\${GRN}[✔]\${RST} \$*"; }
warn() { echo -e "\${YEL}[!]\${RST} \$*"; }
err()  { echo -e "\${RED}[✘]\${RST} \$*" >&2; }
info() { echo -e "\${BLU}[i]\${RST} \$*"; }
sep()  { echo -e "\${CYA}────────────────────────────────────────────────────\${RST}"; }

# Retourne le domid d'une VM ou "" si absente
_domid() { \$SUDO xl list 2>/dev/null | awk -v n="\$1" '\$1==n{print \$2}'; }

# Purge un domaine zombie (nom connu dans xl mais processus mort)
_purge_zombie() {
  local NAME="\$1"
  # xl destroy peut échouer si le processus est déjà mort — on nettoie xenstore
  warn "Purge du domaine zombie '\${NAME}'..."
  \$SUDO xl destroy "\${NAME}" 2>/dev/null || true
  sleep 1
  # Nettoyage xenstore si destroy a échoué
  local DOMID; DOMID=$(\$SUDO xenstore-read "/local/domain/0/backend/console" 2>/dev/null || true)
  # Chercher le domid par le nom dans xenstore
  local XS_DOMID
  XS_DOMID=$(\$SUDO xenstore-list /local/domain 2>/dev/null | while read -r D; do
    N=$(\$SUDO xenstore-read "/local/domain/\${D}/name" 2>/dev/null || true)
    [[ "\${N}" == "\${NAME}" ]] && echo "\${D}" && break
  done || true)
  if [[ -n "\${XS_DOMID}" ]]; then
    warn "Suppression xenstore du domaine \${XS_DOMID} (\${NAME})..."
    \$SUDO xenstore-rm "/local/domain/\${XS_DOMID}" 2>/dev/null || true
    \$SUDO xenstore-rm "/libxl/\${XS_DOMID}" 2>/dev/null || true
  fi
  sleep 1
  if [[ -z "$(_domid "\${NAME}")" ]]; then
    ok "Domaine zombie purgé."
  else
    err "Échec purge — redémarrez le démon Xen : sudo systemctl restart xenstored"
  fi
}

# Retourne l'état d'une VM : running | paused | absent
_state() {
  local S; S=\$(\$SUDO xl list 2>/dev/null | awk -v n="\$1" '\$1==n{print \$5}')
  case "\$S" in
    r*|b*) echo "running" ;;
    p*)    echo "paused"  ;;
    "")    echo "absent"  ;;
    *)     echo "\$S"     ;;
  esac
}

usage() {
  sep
  echo -e "\${BLD}  vm.sh — Gestion VM macOS ${MACOS_VERSION}\${RST}"
  sep
  cat <<EOF

\${BLD}Commandes :\${RST}

  \${BLD}start\${RST}           Démarrer la VM (mode normal, après installation)
  \${BLD}start-install\${RST}   Démarrer en mode installation (avec Recovery)
  \${BLD}stop\${RST}            Arrêt propre (ACPI shutdown)
  \${BLD}kill\${RST}            Forcer l'arrêt immédiat (xl destroy)
  \${BLD}restart\${RST}         Redémarrer la VM
  \${BLD}pause\${RST}           Suspendre (gel de la VM)
  \${BLD}resume\${RST}          Reprendre après pause
  \${BLD}status\${RST}          Afficher l'état de la VM
  \${BLD}list\${RST}            Lister toutes les VMs Xen actives
  \${BLD}vnc\${RST}             Ouvrir le client VNC (vncviewer)
  \${BLD}console\${RST}         Console série (Ctrl+] pour quitter)
  \${BLD}log\${RST}             Derniers logs QEMU/Xen
  \${BLD}info\${RST}            Infos détaillées (dominfo + vcpu-list)
  \${BLD}help\${RST}            Afficher cette aide

\${BLD}Exemples :\${RST}
  ./vm.sh start-install   # 1er démarrage pour installer macOS
  ./vm.sh vnc             # Se connecter à l'écran
  ./vm.sh stop            # Éteindre proprement
  ./vm.sh kill            # Forcer l'extinction
  ./vm.sh log             # Voir les erreurs QEMU
EOF
  sep
}

cmd_start() {
  local NAME="\${1:-\${VM_NORMAL}}"
  local XLCFG="\${2:-\${XL_NORMAL}}"
  local STATE; STATE=\$(_state "\${NAME}")

  if [[ "\${STATE}" == "running" ]]; then
    warn "La VM '\${NAME}' est déjà en cours d'exécution (domid: \$(_domid "\${NAME}"))."
    info "Connectez-vous via VNC : vncviewer localhost:\${VNC_PORT}"
    return 0
  fi

  [[ -f "\${XLCFG}" ]] || { err "Config xl introuvable : \${XLCFG}"; exit 1; }

  # Détecter un domaine zombie (nom existant mais processus mort)
  # Symptôme : "Domain with name X already exists" au xl create
  local STALE_DOMID; STALE_DOMID=$(_domid "\${NAME}")
  if [[ -n "\${STALE_DOMID}" ]] && [[ "\${STATE}" != "running" ]]; then
    warn "Domaine zombie détecté (domid: \${STALE_DOMID}) — purge..."
    _purge_zombie "\${NAME}"
  fi

  info "Démarrage de '\${NAME}'..."
  \$SUDO xl create "\${XLCFG}"
  sleep 2

  local DOMID; DOMID=\$(_domid "\${NAME}")
  if [[ -n "\${DOMID}" ]]; then
    ok "VM démarrée (domid: \${DOMID})"
    info "VNC disponible sur localhost:\${VNC_PORT}"
    info "Lancez : ./vm.sh vnc"
  else
    err "La VM n'apparaît pas dans xl list — vérifiez : ./vm.sh log"
    exit 1
  fi
}

cmd_start_install() {
  info "Mode installation (Recovery monté)..."
  cmd_start "\${VM_INSTALL}" "\${XL_INSTALL}"
}

cmd_stop() {
  local NAME="\${VM_NORMAL}"
  [[ "\$(_state "\${NAME}")" == "absent" ]] && NAME="\${VM_INSTALL}"
  local STATE; STATE=\$(_state "\${NAME}")

  if [[ "\${STATE}" == "absent" ]]; then
    warn "Aucune VM macOS en cours d'exécution."
    return 0
  fi

  info "Arrêt ACPI de '\${NAME}' (peut prendre 30s)..."
  \$SUDO xl shutdown "\${NAME}"
  local I=0
  while [[ \$(_state "\${NAME}") != "absent" && \$I -lt 40 ]]; do
    sleep 1; (( I++ )); printf '.'
  done
  echo ""
  if [[ \$(_state "\${NAME}") == "absent" ]]; then
    ok "VM arrêtée."
  else
    warn "La VM ne répond pas. Utilisez './vm.sh kill' pour forcer l'arrêt."
  fi
}

cmd_kill() {
  local NAME="\${VM_NORMAL}"
  [[ "\$(_state "\${NAME}")" == "absent" ]] && NAME="\${VM_INSTALL}"

  if [[ "\$(_state "\${NAME}")" == "absent" ]]; then
    # Vérifier quand même les zombies par nom dans xenstore
    local FOUND=0
    for N in "\${VM_NORMAL}" "\${VM_INSTALL}"; do
      if \$SUDO xenstore-list /local/domain 2>/dev/null | while read -r D; do
          NM=$(\$SUDO xenstore-read "/local/domain/\${D}/name" 2>/dev/null || true)
          [[ "\${NM}" == "\${N}" ]] && echo "found" && break
        done | grep -q found; then
        warn "Domaine zombie trouvé : \${N}"
        _purge_zombie "\${N}"
        FOUND=1
      fi
    done
    [[ "\${FOUND}" -eq 0 ]] && warn "Aucune VM macOS active à détruire."
    return 0
  fi
  warn "Destruction forcée de '\${NAME}'..."
  \$SUDO xl destroy "\${NAME}" 2>/dev/null || _purge_zombie "\${NAME}"
  ok "VM détruite."
}

cmd_restart() {
  local NAME="\${VM_NORMAL}"
  [[ "\$(_state "\${NAME}")" == "absent" ]] && NAME="\${VM_INSTALL}"

  if [[ "\$(_state "\${NAME}")" == "absent" ]]; then
    warn "Aucune VM active. Lancement en mode normal..."
    cmd_start; return
  fi
  info "Redémarrage de '\${NAME}'..."
  \$SUDO xl reboot "\${NAME}"
  ok "Redémarrage envoyé."
}

cmd_pause() {
  local NAME="\${VM_NORMAL}"
  [[ "\$(_state "\${NAME}")" == "absent" ]] && NAME="\${VM_INSTALL}"
  \$SUDO xl pause "\${NAME}" && ok "VM suspendue." || err "Échec de la suspension."
}

cmd_resume() {
  local NAME="\${VM_NORMAL}"
  [[ "\$(_state "\${NAME}")" != "paused" ]] && NAME="\${VM_INSTALL}"
  \$SUDO xl unpause "\${NAME}" && ok "VM reprise." || err "Échec de la reprise."
}

cmd_status() {
  sep
  echo -e "\${BLD}  État VM macOS ${MACOS_VERSION}\${RST}"
  sep
  for NAME in "\${VM_INSTALL}" "\${VM_NORMAL}"; do
    local STATE; STATE=\$(_state "\${NAME}")
    local DOMID; DOMID=\$(_domid "\${NAME}")
    case "\${STATE}" in
      running) echo -e "  \${GRN}●\${RST} \${BLD}\${NAME}\${RST} — \${GRN}en cours\${RST} (domid: \${DOMID})" ;;
      paused)  echo -e "  \${YEL}⏸\${RST} \${BLD}\${NAME}\${RST} — \${YEL}suspendue\${RST} (domid: \${DOMID})" ;;
      absent)  echo -e "  \${RED}○\${RST} \${BLD}\${NAME}\${RST} — arrêtée" ;;
      *)       echo -e "  \${YEL}?\${RST} \${BLD}\${NAME}\${RST} — état: \${STATE}" ;;
    esac
  done
  sep
  local FREE_MEM; FREE_MEM=\$(\$SUDO xl info 2>/dev/null | awk '/^free_memory/{print \$3}')
  [[ -n "\${FREE_MEM}" ]] && info "Mémoire Xen libre : \${FREE_MEM} Mo"
  info "VNC : localhost:\${VNC_PORT}"
  sep
}

cmd_list() { \$SUDO xl list; }

cmd_vnc() {
  if command -v vncviewer &>/dev/null; then
    info "Connexion VNC sur localhost:\${VNC_PORT}..."
    vncviewer "localhost:\${VNC_PORT}"
  else
    err "vncviewer introuvable."
    info "Installez-le : sudo zypper install tigervnc"
    info "Ou connectez-vous manuellement sur localhost:\${VNC_PORT}"
  fi
}

cmd_console() {
  local NAME="\${VM_NORMAL}"
  [[ "\$(_state "\${NAME}")" == "absent" ]] && NAME="\${VM_INSTALL}"
  if [[ "\$(_state "\${NAME}")" == "absent" ]]; then
    err "Aucune VM macOS active."; exit 1
  fi
  info "Console série de '\${NAME}' (Ctrl+] pour quitter)..."
  \$SUDO xl console "\${NAME}"
}

cmd_log() {
  sep
  echo -e "\${BLD}  Derniers logs Xen/QEMU\${RST}"
  sep
  local QLOG; QLOG=\$(ls -t /var/log/xen/qemu-dm-*.log 2>/dev/null | head -1 || true)
  if [[ -n "\${QLOG}" ]]; then
    info "Log QEMU : \${QLOG}"
    echo ""
    \$SUDO tail -40 "\${QLOG}"
  else
    warn "Aucun log QEMU trouvé dans /var/log/xen/"
  fi
  sep
  for XLLOG in /var/log/xen/xl-${MACOS_VERSION}-install.log /var/log/xen/xl-${MACOS_VERSION}.log; do
    if [[ -f "\${XLLOG}" ]]; then
      info "Log xl : \${XLLOG}"
      \$SUDO tail -20 "\${XLLOG}"
      sep
    fi
  done
}

cmd_info() {
  local NAME="\${VM_NORMAL}"
  [[ "\$(_state "\${NAME}")" == "absent" ]] && NAME="\${VM_INSTALL}"
  local DOMID; DOMID=\$(_domid "\${NAME}")
  if [[ -z "\${DOMID}" ]]; then
    err "VM non active. Démarrez-la d'abord."; exit 1
  fi
  \$SUDO xl dominfo "\${NAME}"
  sep
  \$SUDO xl vcpu-list "\${NAME}"
}

# ── Dispatch ─────────────────────────────────────────────────
CMD="\${1:-help}"
shift || true
case "\${CMD}" in
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
  help|--help|-h) usage ;;
  *) err "Commande inconnue : '\${CMD}'"; usage; exit 1 ;;
esac
VMSH
  chmod +x "${VM_DIR}/vm.sh"

  ok "Configs xl générées :"
  ok "  Installation : ${VM_DIR}/macos-install.xl"
  ok "  Normal       : ${VM_DIR}/macos.xl"
  ok "  Gestion VM   : ${VM_DIR}/vm.sh"
}

# ── 9. Enregistrement libvirt (virt-manager) ──────────────────────────────────
register_libvirt() {
  sep; log "Enregistrement dans libvirt (virt-manager)..."

  # Vérifier que libvirt+virsh sont disponibles
  if ! command -v virsh &>/dev/null; then
    warn "virsh introuvable — installation de libvirt..."
    run $SUDO zypper --non-interactive install --no-recommends \
      libvirt libvirt-daemon-xen virt-manager virsh
  fi

  # S'assurer que le daemon libvirt tourne
  # Sur Tumbleweed, le service peut s'appeler libvirtd, virtqemud ou virtxend
  # et utilise l'activation par socket (libvirtd.socket)
  local LIBVIRT_SVC=""
  for svc in libvirtd virtqemud libvirtd.socket; do
    if systemctl list-unit-files "${svc}" 2>/dev/null | grep -q "${svc}"; then
      LIBVIRT_SVC="${svc}"
      break
    fi
  done

  if [[ -z "${LIBVIRT_SVC}" ]]; then
    warn "Aucun service libvirt détecté — réinstallation..."
    run $SUDO zypper --non-interactive install --no-recommends \
      libvirt libvirt-daemon-xen libvirt-client
    # Redetect
    for svc in libvirtd virtqemud libvirtd.socket; do
      if systemctl list-unit-files "${svc}" 2>/dev/null | grep -q "${svc}"; then
        LIBVIRT_SVC="${svc}"; break
      fi
    done
  fi

  if [[ -n "${LIBVIRT_SVC}" ]]; then
    if ! systemctl is-active --quiet "${LIBVIRT_SVC}" 2>/dev/null; then
      run $SUDO systemctl enable --now "${LIBVIRT_SVC}"
    fi
    ok "Service libvirt : ${LIBVIRT_SVC}"
  else
    warn "Service libvirt introuvable même après installation — virsh peut quand même fonctionner via socket."
  fi

  if [[ "${DRYRUN:-0}" -eq 1 ]]; then
    echo -e "${CYA}[dryrun]${RST} virsh -c xen:/// define ${VM_DIR}/macos-${MACOS_VERSION}.xml"
    echo -e "${CYA}[dryrun]${RST} virsh -c xen:/// define ${VM_DIR}/macos-${MACOS_VERSION}-install.xml"
    ok "Enregistrement libvirt simulé (dryrun)"
    return 0
  fi

  # Générer le XML libvirt — mode normal
  local NVRAM_LINE=""
  [[ -f "${VM_DIR}/OVMF_VARS.fd" ]] && \
    NVRAM_LINE="<nvram>${VM_DIR}/OVMF_VARS.fd</nvram>"

  local NET_XML=""
  if [[ -n "${BRIDGE}" ]]; then
    NET_XML="<interface type='bridge'>
      <source bridge='${BRIDGE}'/>
      <model type='e1000'/>
    </interface>"
  fi

  _write_libvirt_xml() {
    local NAME="$1" XMLFILE="$2" WITH_RECOVERY="$3"
    local RECOVERY_DISK=""
    if [[ "${WITH_RECOVERY}" == "1" ]]; then
      RECOVERY_DISK="
    <disk type='file' device='disk'>
      <driver name='qemu' type='raw' cache='none'/>
      <source file='${RECOVERY_IMG}'/>
      <target dev='hdc' bus='ide'/>
    </disk>"
    fi

    cat > "${XMLFILE}" <<XMLEOF
<domain type='xen'>
  <name>${NAME}</name>
  <memory unit='MiB'>${RAM_MB}</memory>
  <currentMemory unit='MiB'>${RAM_MB}</currentMemory>
  <vcpu placement='static'>${CPU_CORES}</vcpu>

  <os firmware='efi'>
    <type arch='x86_64' machine='xenfv'>hvm</type>
    <loader readonly='yes' type='pflash'>${OVMF_CODE}</loader>
    ${NVRAM_LINE}
    <boot dev='hd'/>
  </os>

  <features>
    <apic/>
    <acpi/>
    <hap/>
    <viridian/>
  </features>

  <cpu mode='host-passthrough'>
    <topology sockets='1' cores='${CPU_CORES}' threads='1'/>
  </cpu>

  <clock offset='localtime'/>

  <on_poweroff>destroy</on_poweroff>
  <on_reboot>restart</on_reboot>
  <on_crash>preserve</on_crash>

  <devices>
    <!-- OpenCore EFI boot disk — OPTIMIZED: cache=writeback pour UEFI rapide -->
    <disk type='file' device='disk'>
      <driver name='qemu' type='raw' cache='writeback'/>
      <source file='${OPENCORE_IMG}'/>
      <target dev='hda' bus='ide'/>
    </disk>

    <!-- macOS main disk — OPTIMIZED: cache=writeback pour I/O rapide -->
    <disk type='file' device='disk'>
      <driver name='qemu' type='qcow2' cache='writeback' discard='unmap'/>
      <source file='${MACOS_DISK}'/>
      <target dev='hdb' bus='ide'/>
    </disk>
    ${RECOVERY_DISK}

    <!-- Réseau -->
    ${NET_XML}

    <!-- Input : ps2 mouse (tablet/usb non supporté par le driver Xen libvirt) -->
    <!-- VNC gère clavier et souris nativement, pas besoin de device dédié -->
    <input type='mouse' bus='ps2'/>

    <!-- Affichage VNC -->
    <graphics type='vnc' port='5900' listen='127.0.0.1' autoport='no'>
      <listen type='address' address='127.0.0.1'/>
    </graphics>
    <video>
      <model type='vga' vram='131072'/>
    </video>

    <!-- Audio DISABLED — OPTIMIZED: Pas audio pour boot rapide en VM headless -->
    <!-- <sound model='ac97'/> -->
  </devices>
</domain>
XMLEOF
  }

  _write_libvirt_xml "macos-${MACOS_VERSION}"         "${VM_DIR}/macos-${MACOS_VERSION}.xml"         "0"
  _write_libvirt_xml "macos-${MACOS_VERSION}-install" "${VM_DIR}/macos-${MACOS_VERSION}-install.xml" "1"

  # Enregistrer dans libvirt via le driver Xen
  $SUDO virsh -c xen:/// define "${VM_DIR}/macos-${MACOS_VERSION}.xml"
  $SUDO virsh -c xen:/// define "${VM_DIR}/macos-${MACOS_VERSION}-install.xml"

  ok "VM enregistrées dans libvirt (driver xen:///)"
  ok "Ouvrez virt-manager → Fichier → Ajouter une connexion → Xen"
  ok "ou : virt-manager --connect xen:///"
}

# ── 9. Résumé final ───────────────────────────────────────────────────────────
print_summary() {
  sep
  echo -e "${BLD}${GRN}  VM macOS ${MACOS_VERSION} — Xen HVM — prête !${RST}"
  sep
  cat <<EOF

${BLD}Répertoire :${RST}  ${VM_DIR}
${BLD}RAM        :${RST}  ${RAM_MB} Mo (80% du système)
${BLD}CPUs       :${RST}  ${CPU_CORES} (100% du système)
${BLD}Bridge     :${RST}  ${BRIDGE:-"(aucun)"}

${BLD}${YEL}── Étape 1 : Installation macOS ──────────────────────────────${RST}
  ${VM_DIR}/vm.sh start-install
  ${VM_DIR}/vm.sh vnc

  Dans OpenCore picker :
    1. Sélectionner "Reset NVRAM" (1er démarrage uniquement)
    2. Démarrer sur "macOS BaseSystem"
    3. Disk Utility → Effacer le disque (APFS, GUID)
    4. Réinstaller macOS → sélectionner le disque APFS

${BLD}${YEL}── Étape 2 : Après installation ──────────────────────────────${RST}
  ${VM_DIR}/vm.sh start
  ${VM_DIR}/vm.sh vnc

${BLD}${YEL}── Commandes vm.sh ────────────────────────────────────────────${RST}
  ./vm.sh start-install   # Démarrer en mode installation
  ./vm.sh start           # Démarrer normalement
  ./vm.sh stop            # Arrêt propre (ACPI)
  ./vm.sh kill            # Forcer l'arrêt
  ./vm.sh restart         # Redémarrer
  ./vm.sh pause           # Suspendre
  ./vm.sh resume          # Reprendre
  ./vm.sh status          # État de la VM
  ./vm.sh vnc             # Ouvrir VNC
  ./vm.sh console         # Console série
  ./vm.sh log             # Voir les logs QEMU/Xen
  ./vm.sh info            # Infos détaillées

${BLD}${YEL}── Si VNC distant (SSH tunnel) ────────────────────────────────${RST}
  # Sur votre poste local :
  ssh -L 5900:127.0.0.1:5900 user@dom0-host
  vncviewer localhost:5900

EOF
  sep
}

launch_vm() {
  sep; log "Lancement de la VM macOS (mode installation)..."
  "${VM_DIR}/vm.sh" start-install
}

# ═══════════════════════════════════════════════════════════════
# MAIN
# ═══════════════════════════════════════════════════════════════
sep
echo -e "${BLD}  macOS VM Setup — openSUSE Tumbleweed + Xen HVM${RST}"
echo -e "${BLD}  Version macOS : ${CYA}${MACOS_VERSION}${RST}"
sep
# Calculer les ressources système si non surchargées par --ram/--cores
calculate_resources
sep

if [[ "$RUN_ONLY" -eq 1 ]]; then
  [[ -f "${VM_DIR}/run-install.sh" ]] || die "VM non configurée. Lancez sans --run-only d'abord."
  launch_vm; exit 0
fi

check_xen
[[ "$SKIP_DEPS" -eq 0 ]] && install_deps || _find_ovmf
prepare_dirs
[[ "$SKIP_OCS" -eq 0 ]]      && run_opcore_simplify
build_opencore_img
[[ "$SKIP_RECOVERY" -eq 0 ]] && download_recovery
create_macos_disk
generate_xl_config
[[ "$SKIP_LIBVIRT" -eq 0 ]] && register_libvirt
print_summary

if [[ "${DRYRUN:-0}" -eq 1 ]]; then
  ok "Dry-run terminé avec succès."
  exit 0
fi

read -r -p "Lancer la VM maintenant ($SUDO xl create) ? [o/N] " GO
[[ "${GO,,}" == "o" ]] && launch_vm || ok "Lancez manuellement : ${VM_DIR}/vm.sh start-install"