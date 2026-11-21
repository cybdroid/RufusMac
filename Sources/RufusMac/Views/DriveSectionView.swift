import SwiftUI
import RufusCore

struct DriveSectionView: View {
    @ObservedObject var vm: AppViewModel

    var body: some View {
        SectionCard(
            title: vm.t("Ziel-Laufwerk", "Target Drive"),
            icon: "externaldrive.connected.to.line.below",
            iconColor: RufusTheme.accentBlue,
            trailing: {
                HStack(spacing: 8) {
                    StatusPill(
                        vm.t("Systemlaufwerke geschützt", "System drives protected"),
                        icon: "lock.shield.fill",
                        color: RufusTheme.accentGreen
                    )

                    Button {
                        vm.refreshDrives()
                    } label: {
                        Image(systemName: "arrow.clockwise")
                            .font(.system(size: 11.5, weight: .semibold))
                            .rotationEffect(.degrees(vm.isRefreshingDrives ? 360 : 0))
                            .animation(vm.isRefreshingDrives ? .linear(duration: 0.7).repeatForever(autoreverses: false) : .default, value: vm.isRefreshingDrives)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .disabled(vm.isRunning)
                    .help(vm.t("USB-Laufwerke neu erkennen", "Rescan USB drives"))
                }
            }
        ) {
            VStack(alignment: .leading, spacing: 10) {
                if vm.drives.isEmpty {
                    HStack(spacing: 10) {
                        Image(systemName: "usb")
                            .font(.system(size: 18))
                            .foregroundStyle(.secondary)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(vm.t("Kein USB-Laufwerk erkannt", "No USB drive detected"))
                                .font(.system(size: 12.5, weight: .medium))
                            Text(vm.t("Schließe einen USB-Stick an — er erscheint automatisch.", "Plug in a USB drive — it will appear automatically."))
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                    }
                    .padding(10)
                    .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.primary.opacity(0.04)))
                } else {
                    Picker("", selection: $vm.selectedDriveID) {
                        ForEach(vm.drives) { drive in
                            Text(drive.displayTitle).tag(Optional(drive.id))
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .disabled(vm.isRunning)

                    if let drive = vm.selectedDrive {
                        HStack(spacing: 8) {
                            StatusPill(drive.busProtocol, icon: "cable.connector", color: RufusTheme.accentCyan)
                            StatusPill(drive.shortSchemeLabel, icon: "square.split.2x1", color: drive.shortSchemeLabel == "Raw / UDF" ? RufusTheme.accentAmber : .secondary)
                            if let firstVol = drive.mountedVolumes.first {
                                StatusPill(firstVol, icon: "folder.fill", color: .secondary)
                            }
                            Spacer()
                            Text(drive.deviceNode)
                                .font(.system(size: 11, weight: .medium, design: .monospaced))
                                .foregroundStyle(.secondary)
                        }

                        if drive.shortSchemeLabel == "Raw / UDF" {
                            HStack(spacing: 6) {
                                Image(systemName: "sparkles")
                                    .font(.system(size: 11))
                                    .foregroundStyle(RufusTheme.accentAmber)
                                Text(vm.t(
                                    "Roh-UDF/Etcher-Abbild erkannt — alte Header werden vor dem Flashen automatisch sauber gelöscht.",
                                    "Raw UDF/Etcher image detected — stale headers will be wiped cleanly before flashing."
                                ))
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                            }
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(RufusTheme.accentAmber.opacity(0.10)))
                        }
                    }
                }

                Toggle(isOn: $vm.includeFixedExternalUSB) {
                    Text(vm.t("Auch externe USB-Festplatten anzeigen (ohne System-SSD)", "Also list fixed external USB hard drives (excludes OS SSD)"))
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                .toggleStyle(.checkbox)
                .disabled(vm.isRunning)
            }
        }
    }
}
