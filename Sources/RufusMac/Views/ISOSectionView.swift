import SwiftUI
import UniformTypeIdentifiers
import RufusCore

struct ISOSectionView: View {
    @ObservedObject var vm: AppViewModel
    @State private var isDropTargeted = false

    var body: some View {
        SectionCard(
            title: vm.t("Startart & ISO-Abbild", "Boot Selection & ISO Image"),
            icon: "opticaldiscdrive.fill",
            iconColor: RufusTheme.accentPurple,
            trailing: {
                Picker("", selection: $vm.bootMode) {
                    Text(vm.t("ISO / Image", "ISO / Image")).tag(BootSelectionMode.isoOrImage)
                    Text(vm.t("Nur formatieren", "Non bootable")).tag(BootSelectionMode.nonBootable)
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .frame(width: 220)
                .disabled(vm.isRunning)
            }
        ) {
            if vm.bootMode == .nonBootable {
                HStack(spacing: 10) {
                    Image(systemName: "eraser.fill")
                        .font(.system(size: 16))
                        .foregroundStyle(RufusTheme.accentAmber)
                    Text(vm.t(
                        "Das Laufwerk wird sauber partitioniert und formatiert, ohne Bootloader oder ISO zu schreiben.",
                        "The drive will be cleanly partitioned and formatted without writing a bootloader or ISO."
                    ))
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    Spacer()
                }
                .padding(10)
                .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.primary.opacity(0.04)))
            } else {
                VStack(alignment: .leading, spacing: 10) {
                    if vm.isInspectingISO {
                        HStack(spacing: 10) {
                            ProgressView()
                                .controlSize(.small)
                            Text(vm.t("Analysiere ISO-Struktur, Bootloader und install.wim…", "Analyzing ISO layout, bootloaders and install.wim…"))
                                .font(.system(size: 12))
                                .foregroundStyle(.secondary)
                            Spacer()
                        }
                        .padding(14)
                        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.primary.opacity(0.04)))
                    } else if let analysis = vm.isoAnalysis {
                        selectedImageCard(analysis)
                    } else {
                        dropZoneCard
                    }

                    if let err = vm.isoInspectError {
                        HStack(spacing: 6) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundStyle(RufusTheme.accentRed)
                            Text(err)
                                .font(.system(size: 11.5))
                                .foregroundStyle(RufusTheme.accentRed)
                        }
                    }
                }
                .onDrop(of: [.fileURL], isTargeted: $isDropTargeted) { providers in
                    handleDrop(providers: providers)
                }
            }
        }
    }

    private var dropZoneCard: some View {
        Button {
            vm.openISOFilePicker()
        } label: {
            HStack(spacing: 14) {
                ZStack {
                    Circle()
                        .fill((isDropTargeted ? RufusTheme.accentBlue : RufusTheme.accentPurple).opacity(0.15))
                        .frame(width: 42, height: 42)
                    Image(systemName: isDropTargeted ? "arrow.down.doc.fill" : "plus.circle.fill")
                        .font(.system(size: 19, weight: .semibold))
                        .foregroundStyle(isDropTargeted ? RufusTheme.accentBlue : RufusTheme.accentPurple)
                }

                VStack(alignment: .leading, spacing: 3) {
                    Text(vm.t("Windows- oder Linux-ISO hierher ziehen", "Drop Windows or Linux ISO here"))
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.primary)
                    Text(vm.t("oder klicken zum Auswählen (.iso, .img, .raw)", "or click to browse (.iso, .img, .raw)"))
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Text(vm.t("Auswählen…", "Select…"))
                    .font(.system(size: 12, weight: .semibold))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(Capsule().fill(RufusTheme.accentBlue.opacity(0.15)))
                    .foregroundStyle(RufusTheme.accentBlue)
            }
            .padding(14)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(isDropTargeted ? RufusTheme.accentBlue.opacity(0.10) : Color.primary.opacity(0.035))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(
                        isDropTargeted ? RufusTheme.accentBlue : Color.primary.opacity(0.14),
                        style: StrokeStyle(lineWidth: isDropTargeted ? 2 : 1.2, dash: [6, 4])
                    )
            )
        }
        .buttonStyle(.plain)
        .disabled(vm.isRunning)
    }

    @ViewBuilder
    private func selectedImageCard(_ a: ISOAnalysis) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 11) {
                ZStack {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(badgeColor(for: a.kind).opacity(0.16))
                        .frame(width: 38, height: 38)
                    Image(systemName: badgeIcon(for: a.kind))
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(badgeColor(for: a.kind))
                }

                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Text(a.fileName)
                            .font(.system(size: 13, weight: .semibold))
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer()
                        Text(a.formattedSize)
                            .font(.system(size: 11.5, weight: .semibold, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }

                    HStack(spacing: 6) {
                        StatusPill(kindTitle(for: a), icon: nil, color: badgeColor(for: a.kind))
                        if a.hasUEFIBootloader {
                            StatusPill("UEFI", icon: "checkmark.circle.fill", color: RufusTheme.accentGreen)
                        }
                        if a.hasLegacyBIOSBootloader {
                            StatusPill("BIOS", icon: "checkmark.circle.fill", color: RufusTheme.accentCyan)
                        }
                    }
                }

                HStack(spacing: 4) {
                    Button {
                        vm.openISOFilePicker()
                    } label: {
                        Image(systemName: "folder")
                            .font(.system(size: 12, weight: .medium))
                            .frame(width: 26, height: 26)
                            .background(RoundedRectangle(cornerRadius: 6).fill(.quaternary))
                    }
                    .buttonStyle(.plain)
                    .disabled(vm.isRunning)
                    .help(vm.t("Andere ISO auswählen", "Choose another ISO"))

                    Button {
                        vm.clearISO()
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 11, weight: .semibold))
                            .frame(width: 26, height: 26)
                            .background(RoundedRectangle(cornerRadius: 6).fill(.quaternary))
                    }
                    .buttonStyle(.plain)
                    .disabled(vm.isRunning)
                    .help(vm.t("Auswahl entfernen", "Clear selection"))
                }
            }

            // Smart > 4 GB WIM / ESD Banner
            if a.kind == .windowsISO && a.exceedsFAT32Limit {
                largeWimBanner(a)
            }

            // Write mode switcher for Linux/Hybrid/Generic ISOs
            if a.kind != .windowsISO {
                HStack(spacing: 10) {
                    Text(vm.t("Schreibmodus:", "Write mode:"))
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundStyle(.secondary)

                    Picker("", selection: $vm.writeMode) {
                        Text(vm.t("ISO-Modus (Dateikopie)", "ISO Mode (File Copy)")).tag(WriteMode.isoFileCopy)
                        Text(vm.t("DD-Image-Modus (Rohdaten)", "DD Image Mode (Raw)")).tag(WriteMode.ddRawImage)
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                    .disabled(vm.isRunning || a.kind == .rawDiskImage)
                }
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(isDropTargeted ? RufusTheme.accentBlue.opacity(0.10) : Color.primary.opacity(0.04))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(isDropTargeted ? RufusTheme.accentBlue : badgeColor(for: a.kind).opacity(0.28), lineWidth: 1)
        )
    }

    @ViewBuilder
    private func largeWimBanner(_ a: ISOAnalysis) -> some View {
        if a.installEsdExceedsFAT32 && vm.fileSystem == .fat32 {
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(RufusTheme.accentAmber)
                Text(vm.t(
                    "install.esd (\(a.formattedInstallImageSize)) > 4 GB ist komprimiert (Solid ESD) und kann nicht für FAT32 gesplittet werden.",
                    "install.esd (\(a.formattedInstallImageSize)) > 4 GB is a solid ESD and cannot be split for FAT32."
                ))
                .font(.system(size: 11))
                .foregroundStyle(.primary)
                Spacer()
                Button(vm.t("Dual-Partition nutzen", "Use Dual-Partition")) {
                    vm.fileSystem = .dualFat32ExFAT
                }
                .controlSize(.small)
                .buttonStyle(.borderedProminent)
            }
            .padding(9)
            .background(RoundedRectangle(cornerRadius: 8).fill(RufusTheme.accentAmber.opacity(0.13)))
        } else if a.installWimNeedsSplit && vm.fileSystem == .fat32 {
            HStack(spacing: 8) {
                Image(systemName: "scissors")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(RufusTheme.accentBlue)
                Text(vm.t(
                    "install.wim (\(a.formattedInstallImageSize)) überschreitet 4 GB — RufusMac teilt sie automatisch per wimlib in install.swm auf (100% UEFI + Secure Boot kompatibel).",
                    "install.wim (\(a.formattedInstallImageSize)) exceeds 4 GB — RufusMac will auto-split it via wimlib into install.swm (100% UEFI + Secure Boot compatible)."
                ))
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            }
            .padding(9)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 8).fill(RufusTheme.accentBlue.opacity(0.10)))
        } else if vm.fileSystem == .dualFat32ExFAT {
            HStack(spacing: 8) {
                Image(systemName: "rectangle.split.2x1.fill")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(RufusTheme.accentGreen)
                Text(vm.t(
                    "Dual-Partition aktiv: Boot-Dateien auf FAT32, große install.wim (\(a.formattedInstallImageSize)) ungeteilt auf ExFAT.",
                    "Dual-Partition active: Boot files on FAT32, large install.wim (\(a.formattedInstallImageSize)) untouched on ExFAT."
                ))
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            }
            .padding(9)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 8).fill(RufusTheme.accentGreen.opacity(0.10)))
        }
    }

    private func badgeColor(for kind: DetectedImageKind) -> Color {
        switch kind {
        case .windowsISO: return RufusTheme.accentBlue
        case .linuxHybridISO: return RufusTheme.accentAmber
        case .rawDiskImage: return RufusTheme.accentCyan
        case .genericISO: return RufusTheme.accentPurple
        }
    }

    private func badgeIcon(for kind: DetectedImageKind) -> String {
        switch kind {
        case .windowsISO: return "square.grid.2x2.fill"
        case .linuxHybridISO: return "terminal.fill"
        case .rawDiskImage: return "internaldrive.fill"
        case .genericISO: return "opticaldisc.fill"
        }
    }

    private func kindTitle(for a: ISOAnalysis) -> String {
        switch a.kind {
        case .windowsISO:
            let lower = a.fileName.lowercased()
            let ver: String
            if lower.contains("win10") || lower.contains("windows10") || lower.contains("windows_10") {
                ver = "Windows 10"
            } else if a.isWindows11Likely {
                ver = "Windows 11"
            } else {
                ver = "Windows ISO"
            }
            let arch = a.windowsArchitecture.map { " (\($0))" } ?? ""
            return "\(ver)\(arch)"
        case .linuxHybridISO:
            return vm.t("Linux Hybrid-ISO", "Linux Hybrid ISO")
        case .rawDiskImage:
            return vm.t("Raw Disk-Image", "Raw Disk Image")
        case .genericISO:
            return "ISO 9660 / UDF"
        }
    }

    private func handleDrop(providers: [NSItemProvider]) -> Bool {
        guard !vm.isRunning else { return false }
        guard let provider = providers.first(where: { $0.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) }) else {
            return false
        }
        provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
            guard let data = item as? Data,
                  let url = URL(dataRepresentation: data, relativeTo: nil) else { return }
            let ext = url.pathExtension.lowercased()
            guard ["iso", "img", "raw", "bin", "dd"].contains(ext) else { return }
            Task { @MainActor in
                vm.selectISO(url: url)
            }
        }
        return true
    }
}
