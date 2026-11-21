# RufusMac

> **Ein moderner, nativer Rufus-Rewrite für Intel macOS (x86_64)** — entwickelt mit Swift & SwiftUI, um **Windows 10/11 ISOs** (und Linux-/Hybrid-ISOs) zuverlässig bootfähig auf USB-Sticks zu schreiben.

## Warum RufusMac?

Tools wie Balena Etcher schreiben ISOs als Rohdaten (`dd`) auf den USB-Stick. Bei Linux-Hybrid-ISOs funktioniert das, **bei Windows 10/11 ISOs schlägt es jedoch fehl**:
- Windows-ISOs sind keine Hybrid-Images, sondern reine UDF-Abbilder ohne USB-Partitionstabelle.
- Die Datei `sources/install.wim` ist bei modernen Windows-10/11-ISOs größer als **4 GB** und passt nicht ohne Weiteres auf eine FAT32-UEFI-Partition.
- Legacy-BIOS-Systeme benötigen echte **Windows NT6/10/11 MBR- und VBR-Bootsektoren** (`BOOTMGR`) sowie eine als aktiv (`0x80`) markierte Partition.

**RufusMac** löst all diese Probleme nativ auf macOS Intel — komplett eigenständig ohne Homebrew-Zwang und in einer modernen SwiftUI-Oberfläche.

---

## Features

| Feature | Beschreibung |
|---|---|
| **GPT (UEFI — ohne CSM)** | Saubere GUID-Partitionstabelle für moderne PCs, Windows 11 & Secure Boot. |
| **MBR (BIOS oder UEFI-CSM)** | Schreibt echten Windows 7/10/11 MBR, Disk-Signatur, FAT32/ExFAT NT6 `BOOTMGR`-VBR (`ms-sys`) und Active-Flag (`0x80`). |
| **Dateisystem-Auswahl** | **FAT32 (Auto WIM-Split)**, **ExFAT + FAT32 Boot (Dual-Partition)**, **ExFAT (Einzelpartition)**, sowie **APFS / HFS+** im Formatierungsmodus. |
| **Automatisches `install.wim`-Splitting** | Teilt `sources/install.wim` > 4 GB automatisch via gebündeltem `wimlib-imagex` in `install.swm` / `install2.swm` — 100% UEFI + Secure Boot kompatibel. |
| **Dual-Partition-Modus** | Legt eine FAT32-Bootpartition (`efi/`, `boot/`, `boot.wim`) + eine ExFAT-Datenpartition (`install.wim` ungeteilt) an. |
| **Windows-Anpassungen (`autounattend.xml`)** | Optionale Rufus-Tweaks: TPM 2.0 / Secure Boot / 4 GB RAM Bypass (`LabConfig`), Microsoft-Konto-Bypass (`BypassNRO` + lokales Konto), Datenschutz-Fragen überspringen. |
| **Linux / Raw Disk Images** | Automatische Erkennung von Windows-, Linux-Hybrid- und Raw-Images (`.iso`, `.img`, `.raw`) mit Wahl zwischen **ISO-Modus** und **DD-Image-Modus**. |
| **Systemlaufwerk-Schutz** | Schützt interne Laufwerke und externe macOS-Boot-SSDs (inkl. APFS-Container-Auflösung) auf UI- und Helper-Ebene. |
| **Live USB Hot-Plug & Prüfsummen** | Automatische USB-Erkennung über `DiskArbitration`, Drag & Drop, Live-Log-Drawer, MD5 / SHA-1 / SHA-256 Prüfsummen-Rechner, DE/EN-Oberfläche. |

---

## Architektur

```
RufusMac/
├── Sources/
│   ├── RufusCore/               # DiskDiscovery, ISOInspector, FlashEngine, AutoUnattendGenerator, PrivilegeRunner
│   ├── rufusmac-helper/         # Privilegierter nativer CLI-Helper (JSONL-Fortschritt, Abbruch ohne 2. Passwort)
│   └── RufusMac/                # Native macOS SwiftUI App (Theme, Views, AppViewModel)
├── Tests/SelfTest/              # End-to-End-Testsuite auf virtuellen Disk-Images (GPT, MBR, Dual-Partition, DD, WIM-Split)
├── scripts/
│   ├── build-helpers.sh         # Kompiliert statisches wimlib-imagex (1.14.5) & ms-sys (2.8.0) für Intel x86_64
│   ├── generate-icon.swift      # Erzeugt macOS Squircle AppIcon.icns via CoreGraphics
│   ├── build-app.sh             # Baut Release RufusMac.app inkl. Helpers & Ad-hoc-Signatur
│   └── install-dock.sh          # Installiert nach /Applications/RufusMac.app und pinnt ins Dock
└── Resources/Info.plist
```

---

## Voraussetzungen & Bauen (macOS Intel x86_64)

Benötigt lediglich die **macOS Command Line Tools** (`xcode-select --install`), **macOS 13+** (Intel x86_64) — kein Homebrew und kein vollständiges Xcode erforderlich!

```bash
# 1. Repository klonen
git clone https://github.com/cybdroid/RufusMac.git
cd RufusMac

# 2. Release-App bauen (kompiliert automatisch wimlib-imagex, ms-sys, Swift-Binaries & AppIcon)
./scripts/build-app.sh

# 3. In /Applications installieren und ins macOS Dock legen
./scripts/install-dock.sh
```

### End-to-End Tests ausführen

Die Testsuite testet Laufwerksschutz, ISO-Analyse, `autounattend.xml`, echtes `wimlib`-Splitting sowie GPT-, Dual-Partition-, MBR-NT6- und DD-Flash-Vorgänge sicher auf temporären virtuellen `.img`-Laufwerken:

```bash
swift run rufusmac-selftest
```

---

## Danksagung & Lizenz

Inspiriert von [Rufus](https://rufus.ie/) (Pete Batard). Verwendet die Open-Source-Komponenten [wimlib](https://wimlib.net/) (Eric Biggers) und [ms-sys](https://ms-sys.sourceforge.net/) (Henrik Carlqvist).

Veröffentlicht unter **GPL-3.0-or-later** (siehe [LICENSE](LICENSE)).
