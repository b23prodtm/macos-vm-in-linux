# 🚀 Quick Start — Xen macOS VM (Optimisé)

## ✨ What Changed

Le script **détecte automatiquement** votre système et alloue :
- **RAM : 80% du système** (par défaut)
- **CPU : 100% du système** (par défaut)

### Exemples

| Système | RAM | CPU |
|---------|-----|-----|
| 32 GB RAM, 8 CPU | **25.6 GB** | **8 cores** |
| 16 GB RAM, 4 CPU | **12.8 GB** | **4 cores** |
| 64 GB RAM, 16 CPU | **51.2 GB** | **16 cores** |

---

## 🚀 Usage

### Option 1: Allocation Automatique (Recommandé)

```bash
bash setup-macos-vm-xen-optimized.sh
```

**Le script détecte et affiche :**
```
✔ Système détecté: 32000MB RAM, 8 CPU(s)
✔ Allocation VM (défaut): 25600MB RAM (80%), 8 CPU(s) (100%)
```

---

### Option 2: Personnalisé (Override)

```bash
# Utiliser 50% RAM et 4 cores seulement
bash setup-macos-vm-xen-optimized.sh --ram 16384 --cores 4

# Autre version macOS
bash setup-macos-vm-xen-optimized.sh --macos sonoma --ram 20480 --cores 6

# Disk plus grand
bash setup-macos-vm-xen-optimized.sh --disk-size 200G
```

---

## 📊 Performance Expectations

| Configuration | Boot Time (Debug OC) | Boot Time (Release OC) |
|---|---|---|
| 4 CPU, 8GB RAM (Xen) | ~90-120s | ~50-70s |
| 8 CPU, 16GB RAM (Xen) | ~60-90s | ~30-50s |
| **16 CPU, 25GB RAM (Xen)** | **~45-60s** | **~25-40s** |

**→ Plus de ressources = boot plus rapide (parallélisation UEFI)**

---

## ⚡ Optimizations Included

✅ **Disk Cache**: `cache=writeback` (fast I/O)  
✅ **Audio**: Disabled (no sound = faster boot)  
✅ **CPU**: Host passthrough (max performance)  
✅ **UEFI**: Optimized firmware loading  

---

## 🎯 Next Steps After Setup

1. **Lancer la VM**:
   ```bash
   cd ~/VMs/macos-ventura
   ./vm.sh start-install
   ```

2. **Connecter VNC**:
   ```bash
   vncviewer localhost:5900
   ```

3. **Installer macOS** via macOS BaseSystem

4. **Après installation**:
   ```bash
   ./vm.sh start
   ./vm.sh vnc
   ```

---

## 🔧 Parameters Reference

```bash
--macos VERSION      sequoia | sonoma | ventura | monterey | big-sur
--disk-size SIZE     80G (default) — la taille de votre disque macOS
--ram MB             Auto-détecté = 80% du système (override possible)
--cores N            Auto-détecté = 100% du système (override possible)
--bridge BRIDGE      xenbr0 (default) — votre bridge réseau Xen
--vm-dir PATH        ~/VMs/macos-VERSION (default)
--ocs-dir PATH       ~/opcore-simplify (default)
--skip-deps          Sauter l'install des paquets
--skip-ocs           Si OpenCore déjà généré
--skip-recovery      Si BaseSystem déjà téléchargé
--dryrun             Test sans rien créer
--help               Voir toutes les options
```

---

## 🐛 Troubleshooting

### Boot lent (>120s)
- ✅ Vérifier que OpenCore est en **release** (pas debug)
- ✅ Vérifier allocation: `xl list | grep macos`
- ✅ Augmenter `--cores` et `--ram` si possible

### VM crash au démarrage
- ↓ Réduire CPU/RAM temporairement
- ✅ Vérifier `/proc/xen` existe (dom0 Xen)
- ✅ Vérifier bridge réseau: `ip link show xenbr0`

### Pas de VNC
- ✅ Vérifier firewall: `sudo netstat -tlnp | grep 5900`
- ✅ Vérifier libvirt: `virsh -c xen:/// list`

---

## 📚 Advanced: Manual Resource Override

Si vous voulez contrôler précisément l'allocation :

```bash
# Exemple: Système avec 64GB RAM, 32 CPU
# Mais vous voulez garder 16GB pour le système

# Calcul: 64GB - 16GB = 48GB pour VM
# 48 * 1024 = 49152 Mo (48GB en Mo)

bash setup-macos-vm-xen-optimized.sh --ram 49152 --cores 24
```

---

## 📋 Files Created

```
~/VMs/macos-ventura/
├── OpenCore.img           ← EFI bootloader (généré par OpCore Simplify)
├── macos.qcow2            ← Disque principal macOS
├── BaseSystem.img         ← Récupération macOS (téléchargé)
├── OVMF_VARS.fd           ← Firmware UEFI persistant
├── macos-ventura.xml      ← Config libvirt (démarrage normal)
├── macos-ventura-install.xml
├── vm.sh                  ← Script helper (start/stop/vnc/logs)
└── run-*.sh               ← Scripts de lancement xl
```

---

## 💡 Tips

- **Pour boot rapide** : Utilisez OpenCore **release build** (pas debug)
- **Pour stabilité** : Ne dépassez pas 90% des ressources système
- **Pour VNC distant** : Tunnel SSH (voir guide principal)
- **Pour performance** : Augmenter cache à `writeback` dans libvirt XML

---

**Version**: optimized-xen-2025  
**Compatibilité**: openSUSE Tumbleweed + Xen HVM  
**Status**: ✅ Production-ready
