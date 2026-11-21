import SwiftUI
import RufusCore

struct PartitionFileSystemView: View {
    @ObservedObject var vm: AppViewModel

    var body: some View {
        VStack(spacing: 12) {
            // Card 1: Partition Scheme & Target System (GPT vs MBR)
            SectionCard(
                title: vm.t("Partitionsschema & Zielsystem", "Partition Scheme & Target System"),
                icon: "cpu.fill",
                iconColor: RufusTheme.accentCyan
            ) {
                if vm.isDDModeActive {
                    ddModeDisabledBanner
                } else {
                    HStack(spacing: 10) {
                        schemeCard(.gpt)
                        schemeCard(.mbr)
                    }
                }
            }

            // Card 2: Format Options (File System, Label, Cluster Size, Advanced)
            SectionCard(
                title: vm.t("Formatierungsoptionen", "Format Options"),
                icon: "slider.horizontal.3",
                iconColor: RufusTheme.accentAmber
            ) {
                if vm.isDDModeActive {
                    ddModeDisabledBanner
                } else {
                    VStack(alignment: .leading, spacing: 12) {
                        // File System & Cluster Size Row
                        HStack(alignment: .top, spacing: 12) {
                            VStack(alignment: .leading, spacing: 5) {
                                Text(vm.t("Dateisystem", "File System"))
                                    .font(.system(size: 11.5, weight: .medium))
                                    .foregroundStyle(.secondary)

                                Picker("", selection: $vm.fileSystem) {
                                    ForEach(vm.availableFileSystems) { fs in
                                        Text(vm.isGerman ? fs.titleDE : fs.titleEN).tag(fs)
                                    }
                                }
                                .labelsHidden()
                                .pickerStyle(.menu)
                                .disabled(vm.isRunning)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)

                            VStack(alignment: .leading, spacing: 5) {
                                Text(vm.t("Clustergröße", "Cluster Size"))
                                    .font(.system(size: 11.5, weight: .medium))
                                    .foregroundStyle(.secondary)

                                Picker("", selection: $vm.clusterSize) {
                                    ForEach(ClusterSize.allCases) { cs in
                                        Text(cs.displayName(isGerman: vm.isGerman)).tag(cs)
                                    }
                                }
                                .labelsHidden()
                                .pickerStyle(.menu)
                                .disabled(vm.isRunning || vm.fileSystem == .apfs || vm.fileSystem == .hfsPlus)
                            }
                            .frame(width: 192, alignment: .leading)
                        }

                        // Contextual filesystem explanation
                        Text(vm.isGerman ? vm.fileSystem.subtitleDE : vm.fileSystem.subtitleEN)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)

                        // Volume Label Row
                        VStack(alignment: .leading, spacing: 5) {
                            HStack {
                                Text(vm.t("Volumebezeichnung", "Volume Label"))
                                    .font(.system(size: 11.5, weight: .medium))
                                    .foregroundStyle(.secondary)
                                Spacer()
                                Text("\(vm.fileSystem == .fat32 ? "FAT32" : vm.fileSystem.rawValue): \(vm.sanitizedVolumeLabelPreview)")
                                    .font(.system(size: 10.5, weight: .medium, design: .monospaced))
                                    .foregroundStyle(.secondary)
                            }

                            TextField(vm.t("z.B. WIN11_USB", "e.g. WIN11_USB"), text: $vm.volumeLabel)
                                .textFieldStyle(.roundedBorder)
                                .disabled(vm.isRunning)
                        }

                        Divider()
                            .opacity(0.5)

                        // Collapsible Advanced Options
                        DisclosureGroup(isExpanded: $vm.showAdvancedOptions) {
                            VStack(alignment: .leading, spacing: 8) {
                                Toggle(isOn: $vm.quickFormat) {
                                    Text(vm.t("Schnellformatierung", "Quick format"))
                                        .font(.system(size: 12))
                                }
                                .toggleStyle(.checkbox)

                                Toggle(isOn: $vm.wipePartitionTable) {
                                    Text(vm.t("Alte Partitionstabelle & UDF-Header komplett löschen (empfohlen)", "Wipe existing partition table & UDF headers (recommended)"))
                                        .font(.system(size: 12))
                                }
                                .toggleStyle(.checkbox)

                                Toggle(isOn: $vm.autoEjectAfterFlash) {
                                    Text(vm.t("USB-Laufwerk nach erfolgreichem Abschluss automatisch auswerfen", "Automatically eject USB drive after completion"))
                                        .font(.system(size: 12))
                                }
                                .toggleStyle(.checkbox)
                            }
                            .padding(.top, 6)
                            .disabled(vm.isRunning)
                        } label: {
                            Text(vm.t("Erweiterte Formatierungsoptionen", "Advanced format options"))
                                .font(.system(size: 11.5, weight: .medium))
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
    }

    private func schemeCard(_ scheme: PartitionScheme) -> some View {
        let isSelected = vm.partitionScheme == scheme
        let isDisabled = vm.isRunning || (scheme == .mbr && vm.fileSystem == .apfs)

        return Button {
            withAnimation(.easeInOut(duration: 0.16)) {
                vm.partitionScheme = scheme
            }
        } label: {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text(scheme.rawValue)
                        .font(.system(size: 14, weight: .bold, design: .rounded))
                        .foregroundStyle(isSelected ? RufusTheme.accentBlue : .primary)

                    Text(vm.isGerman ? scheme.targetSystemDE : scheme.targetSystemEN)
                        .font(.system(size: 11, weight: .medium))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(
                            Capsule().fill(isSelected ? RufusTheme.accentBlue.opacity(0.16) : Color.primary.opacity(0.07))
                        )
                        .foregroundStyle(isSelected ? RufusTheme.accentBlue : .secondary)

                    Spacer()

                    Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(isSelected ? RufusTheme.accentBlue : .secondary.opacity(0.4))
                }

                Text(vm.isGerman ? scheme.descriptionDE : scheme.descriptionEN)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(11)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .fill(isSelected ? RufusTheme.accentBlue.opacity(0.09) : Color.primary.opacity(0.03))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .strokeBorder(
                        isSelected ? RufusTheme.accentBlue.opacity(0.8) : Color.primary.opacity(0.10),
                        lineWidth: isSelected ? 1.5 : 1
                    )
            )
            .opacity(isDisabled ? 0.5 : 1.0)
        }
        .buttonStyle(.plain)
        .disabled(isDisabled)
    }

    private var ddModeDisabledBanner: some View {
        HStack(spacing: 8) {
            Image(systemName: "info.circle.fill")
                .foregroundStyle(RufusTheme.accentCyan)
            Text(vm.t(
                "Im DD-Image-Modus werden Partitionsschema und Dateisystem 1:1 direkt aus dem Image übernommen.",
                "In DD Image Mode, partition scheme and file system are written bit-for-bit directly from the image."
            ))
            .font(.system(size: 11.5))
            .foregroundStyle(.secondary)
            Spacer()
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(RufusTheme.accentCyan.opacity(0.09)))
    }
}
