[![Test setup scripts (--skip-ocs --dryrun)](https://github.com/b23prodtm/macos-vm-in-linux/actions/workflows/test-dryrun.yml/badge.svg?branch=fix%2Fcreatevm)](https://github.com/b23prodtm/macos-vm-in-linux/actions/workflows/test-dryrun.yml)

# macOS VM via OpenCore Simplify — openSUSE Tumbleweed + QEMU/KVM

> **Prérequis matériels** : CPU Intel ou AMD avec VT-x/AMD-V, 16 Go RAM recommandés,
> ~100 Go d'espace disque libre. Compatible Xen dom0 avec KVM pass-through.

---

## Architecture de la solution

```
┌─────────────────────────────────────────────────────────────────┐
│  openSUSE Tumbleweed (hôte)                                     │
│                                                                 │
│  ┌──────────────────────────────────────────────────────────┐  │
│  │  QEMU/KVM  (machine q35 + OVMF UEFI)                     │  │
│  │                                                          │  │
│  │  ┌────────────┐  ┌──────────────┐  ┌─────────────────┐  │  │
│  │  │ OpenCore   │  │  macOS HDD   │  │ BaseSystem      │  │  │
│  │  │ (EFI ESP)  │  │  (qcow2)     │  │ Recovery (raw)  │  │  │
│  │  │ sata.0     │  │  sata.1      │  │ sata.3          │  │  │
│  │  └─────┬──────┘  └──────────────┘  └─────────────────┘  │  │
│  │        │ EFI généré par OpCore Simplify                   │  │
│  │        ▼                                                  │  │
│  │  ┌─────────────┐                                         │  │
│  │  │  macOS      │  CPU: host-passthrough (GenuineIntel)   │  │
│  │  │  (boote)    │  RAM: 8G  │  CPUs: 4                   │  │
│  │  └─────────────┘  GPU: vmware-svga │ NET: vmxnet3       │  │
│  └──────────────────────────────────────────────────────────┘  │
└─────────────────────────────────────────────────────────────────┘
```

---

## Utilisation rapide

```bash
# Cloner / copier ce dossier
chmod +x setup-macos-vm.sh

# Installation complète (ventura par défaut)
bash setup-macos-vm.sh

# Choisir une version spécifique
bash setup-macos-vm.sh --macos sonoma --disk-size 120G --ram 12G

# Si EFI déjà généré par OpCore Simplify
bash setup-macos-vm.sh --macos ventura --skip-ocs

# Relancer la VM uniquement
bash setup-macos-vm.sh --run-only
```

---

## Flux d'installation détaillé

### 1. Dépendances zypper

Le script installe automatiquement :

| Paquet | Rôle |
|---|---|
| `qemu-full` | Émulateur x86_64 complet |
| `qemu-ovmf-x86_64` | Firmware UEFI (OVMF) |
| `qemu-tools` | `qemu-img`, `qemu-nbd` |
| `dmidecode` | Lecture DMI/SMBIOS (OpCore Simplify) |
| `acpica` | `iasl` pour tables ACPI |
| `p7zip-full` | Extraction archives macOS |

### 2. OpCore Simplify — conseils pour profil VM

Quand OpCore Simplify démarre en interactif :

- **SMBIOS** : choisir `MacPro7,1` (macOS Ventura/Sonoma/Sequoia)  
  ou `iMacPro1,1` (Monterey/Big Sur)
- **GPU** : ne cocher aucun GPU réel → la VM utilisera `vmware-svga`
- **USB** : choisir `USBInjectAll` (pas USBToolBox, incompatible Linux)
- **Ethernet** : `vmxnet3` ou `e1000` selon le profil

### 3. Images disque créées

```
~/VMs/macos-ventura/
├── OpenCore.img      # ESP FAT32 200 Mo avec EFI OpenCore
├── macos.qcow2       # Disque principal macOS (80G par défaut)
├── BaseSystem.img    # Recovery macOS (téléchargé via macrecovery.py)
├── OVMF_VARS.fd      # Variables UEFI persistantes de la VM
├── run-macos.sh          # Lancement mode installation (Recovery monté)
└── run-macos-installed.sh # Lancement mode normal (sans Recovery)
```

### 4. Premier démarrage — ordre de boot OpenCore

```
OpenCore Picker
├── [Reset NVRAM]           ← Faire au tout premier boot
├── macOS BaseSystem        ← Recovery pour installation
└── macOS Ventura           ← Après installation terminée
```

### 5. Partitionnement dans le Recovery

1. **Disk Utility** → View All Devices
2. Sélectionner le disque virtuel QEMU (≈80 Go)
3. **Effacer** → Format : APFS / Scheme : GUID Partition Map
4. Fermer Disk Utility → **Réinstaller macOS**

---

## Configuration QEMU détaillée

### Machine (`-machine q35`)

| Option | Valeur | Raison |
|---|---|---|
| `accel=kvm` | KVM | Performance native |
| `usb=on` | — | Bus USB pour clavier/souris |
| `vmport=off` | — | Évite les conflits VMware |
| `smbios-entry-point-type=64` | 64 bits | Requis macOS moderne |

### CPU (`-cpu host,...`)

```
vendor=GenuineIntel    # macOS refuse les CPU AMD sans patch
+sse3,+sse4.2,+avx2    # Instructions requises par macOS 12+
+aes,+xsave            # Performances crypto
kvm=on                 # Expose KVM à l'OS guest
vmware-cpuid-freq=on   # TSC frequency correcte
```

> **AMD** : si votre hôte est AMD, ajoutez `+topoext` et vérifiez  
> qu'AMD-V est actif. macOS peut nécessiter le patch `cpuid=0x0306a9`.

### Stockage (`-device ide-hd,bus=sata.N`)

| sata.0 | OpenCore EFI (boot) |
|---|---|
| sata.1 | Disque macOS principal |
| sata.3 | Recovery BaseSystem (mode install) |

> NVMe virtio n'est **pas** supporté nativement par macOS sans kext tiers.  
> IDE/AHCI est plus compatible.

### Réseau

```
-device vmxnet3,netdev=net0   # Meilleure perf, nécessite VMware Tools
# Alternative sans drivers :
-device e1000-82545em,netdev=net0
```

### Affichage

```
-device vmware-svga,vgamem_mb=128   # Résolution jusqu'à 2560×1600
-display sdl,gl=off                 # SDL (Xorg requis)
# Alternatives :
-display gtk                        # Interface GTK
-display spice-app                  # SPICE (avec virt-viewer)
```

---

## Spécificités Xen dom0

Si vous tournez sur un hôte **Xen dom0** avec QEMU :

```bash
# Vérifier que xen-kvm est disponible
ls /dev/kvm && echo "KVM OK dans Xen dom0"

# Si /dev/kvm absent, charger le module
sudo modprobe kvm_intel   # ou kvm_amd

# QEMU dans Xen dom0 utilise le backend Xen par défaut
# Le script utilise accel=kvm qui fonctionne via xen-kvm
```

> Pour une VM **HVM Xen native** (xl / libxl) sans QEMU autonome,  
> une configuration xl différente est nécessaire — demandez-le séparément.

---

## Dépannage

### Redémarrage de la VM

```
cd ~/VMs/macos-ventura
bash vm.sh kill && bash vm.sh restart && bash vm.sh vnc
```

### Écran noir au démarrage

```
# Dans OpenCore, appuyer sur Espace sur l'entrée macOS → Options
# Ajouter les boot-args :
-v keepsyms=1 debug=0x100
```

### Freeze/panic ACPI

```bash
# Dans config.plist d'OpenCore, section ACPI → Quirks :
RebaseRegions = true
ResetLogoStatus = true
```

### Performance faible

```bash
# Vérifier KVM actif dans la VM
# Dans macOS Terminal :
sysctl -a | grep hw.optional

# Sur l'hôte :
dmesg | grep -i kvm
# Doit afficher : kvm: Nested Virtualization enabled
```

### macrecovery.py échoue

```bash
# Essayer manuellement avec un autre Board ID :
python3 macrecovery.py -b Mac-4B682C642B45593E -m 00000000000000000 download

# Ou utiliser gibMacOS (interface graphique) :
# https://github.com/corpnewt/gibMacOS
```

### `sgdisk` absent

```bash
sudo zypper install gptfdisk
```

---

## Mise à jour de la configuration OpenCore (config.plist)

Cette procédure permet de modifier le `config.plist` généré par OpCore Simplify
et de reconstruire l'image `OpenCore.img` sans relancer une installation complète.

### Cas d'usage typiques

- Corriger un paramètre de boot (boot-args, SecureBootModel, PickerMode…)
- Ajouter ou désactiver un kext
- Appliquer un fix spécifique à la VM (LapicKernelPanic, TscSyncTimeout…)
- Mettre à jour OpenCore vers une nouvelle version

### Workflow

```bash
# 1. Localiser le config.plist dans les résultats d'OpCore Simplify
ls ~/opcore-simplify/Results/EFI/OC/config.plist

# 2. Éditer le fichier directement
nano ~/opcore-simplify/Results/EFI/OC/config.plist
# ou copier un config.plist préparé à la place
cp /chemin/vers/mon/config.plist ~/opcore-simplify/Results/EFI/OC/config.plist

# 3. Reconstruire uniquement OpenCore.img (--skip-ocs = EFI déjà prêt)
sudo bash setup-macos-vm-xen.sh \
  --macos big-sur \
  --skip-deps \
  --skip-ocs \
  --skip-recovery \
  --skip-libvirt
# → Le script demande "Reconstruire l'image existante ? [o/N]" → répondre o

# 4. Relancer la VM
~/VMs/macos-big-sur/vm.sh kill 2>/dev/null || true
~/VMs/macos-big-sur/vm.sh start-install
~/VMs/macos-big-sur/vm.sh vnc
```

### Paramètres recommandés pour une VM Xen

Les réglages suivants sont appliqués automatiquement par OpCore Simplify
quand il détecte un environnement Xen/QEMU (branche `fix/validator`).
Si vous éditez le `config.plist` manuellement, vérifiez ces valeurs :

| Section | Clé | Valeur VM | Raison |
|---|---|---|---|
| `Misc.Boot` | `PickerMode` | `Builtin` | OpenCanopy nécessite `Resources/` absent en VM |
| `Misc.Security` | `SecureBootModel` | `Disabled` | Pas de puce T2 en VM |
| `Misc.Security` | `DmgLoading` | `Any` | Recovery non signé possible |
| `Misc.Security` | `ApECID` | `0` | Désactive la personnalisation SB |
| `Kernel.Quirks` | `LapicKernelPanic` | `true` | Interruptions LAPIC non masquées sous Xen |
| `Kernel.Quirks` | `ProvideCurrentCpuInfo` | `true` | TSC = 0 Hz dans Xen |
| `Booter.Quirks` | `RebuildAppleMemoryMap` | `true` | GetMemoryMap corrompu dans Xen |
| `UEFI.Drivers` | `OpenCanopy.efi` | `Enabled: false` | Pas de dossier `Resources/` en VM |
| `UEFI.Output` | `TextRenderer` | `SystemGeneric` | Compatible VGA Xen |
| `UEFI.Output` | `Resolution` | `1024x768` | VGA Xen sans détection auto |
| `UEFI.Output` | `DirectGopRendering` | `true` | Rendu GOP direct Xen |
| `UEFI.Quirks` | `TscSyncTimeout` | `1000` | Sync TSC entre vCPUs Xen |
| `UEFI.Quirks` | `DisableSecurityPolicy` | `true` | OC 0.9.7+ force x86legacy sinon |

### Vérification sans redémarrer la VM

Pour inspecter le `config.plist` actuellement monté dans `OpenCore.img` :

```bash
# Monter l'image en lecture seule
sudo losetup -Pf --read-only ~/VMs/macos-big-sur/OpenCore.img
sudo mount -o ro /dev/loop0p1 /mnt/efi

# Lire la config active
grep -A1 "PickerMode\|SecureBootModel\|DisableSecurityPolicy" /mnt/efi/EFI/OC/config.plist

# Démonter
sudo umount /mnt/efi
sudo losetup -d /dev/loop0
```

---

## Mise à jour de l'EFI OpenCore (régénération complète)

Après une mise à jour d'OpenCore Simplify ou de votre config :

```bash
# Régénérer l'EFI
cd ~/opcore-simplify && python3 main.py

# Reconstruire uniquement l'image OpenCore
bash setup-macos-vm.sh --macos ventura --skip-deps --skip-recovery
bash setup-macos-vm.sh --macos ventura --skip-deps --skip-recovery --skip-ocs

```

---

## Références

- [OpCore Simplify](https://github.com/b23prodtm/OpCore-Simplify)
- [OpenCore Install Guide](https://dortania.github.io/OpenCore-Install-Guide/)
- [macrecovery.py](https://github.com/acidanthera/OpenCorePkg/tree/master/Utilities/macrecovery)
- [QEMU macOS (OSX-KVM)](https://github.com/kholia/OSX-KVM)
