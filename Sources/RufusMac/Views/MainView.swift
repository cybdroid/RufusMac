import SwiftUI

struct MainView: View {
    @ObservedObject var vm: AppViewModel

    var body: some View {
        ZStack(alignment: .top) {
            // Subtle ambient top glow reacting to app state
            ambientGlow
                .frame(height: 180)
                .allowsHitTesting(false)

            VStack(spacing: 0) {
                HeaderView(vm: vm)

                Divider().opacity(0.45)

                ScrollView {
                    VStack(spacing: 12) {
                        DriveSectionView(vm: vm)
                        ISOSectionView(vm: vm)
                        PartitionFileSystemView(vm: vm)

                        if vm.showWindowsOptionsCard {
                            WindowsOptionsView(vm: vm)
                                .transition(.opacity.combined(with: .move(edge: .top)))
                        }

                        if vm.showLogDrawer {
                            LogDrawerView(vm: vm)
                                .transition(.opacity.combined(with: .move(edge: .bottom)))
                        }
                    }
                    .padding(.horizontal, 18)
                    .padding(.vertical, 14)
                    .animation(.spring(response: 0.3, dampingFraction: 0.85), value: vm.showWindowsOptionsCard)
                    .animation(.spring(response: 0.3, dampingFraction: 0.85), value: vm.showLogDrawer)
                }

                ProgressFooterView(vm: vm)
            }
        }
        .frame(minWidth: 580, idealWidth: 620, minHeight: 680, idealHeight: 770)
        .sheet(isPresented: $vm.showChecksumSheet) {
            ChecksumSheetView(vm: vm)
        }
        .alert(
            vm.t("WARNUNG: Alle Daten werden gelöscht!", "WARNING: All Data Will Be Destroyed!"),
            isPresented: $vm.showConfirmAlert
        ) {
            Button(vm.t("Abbrechen", "Cancel"), role: .cancel) {}
            Button(vm.t("Löschen & Starten", "Erase & Start"), role: .destructive) {
                vm.confirmAndStartFlash()
            }
        } message: {
            Text(confirmAlertMessage)
        }
    }

    private var ambientGlow: some View {
        let glowColor: Color = {
            switch vm.runState {
            case .idle: return RufusTheme.accentBlue
            case .running: return RufusTheme.accentAmber
            case .completed: return RufusTheme.accentGreen
            case .cancelled: return RufusTheme.accentAmber
            case .failed: return RufusTheme.accentRed
            }
        }()

        return RadialGradient(
            colors: [glowColor.opacity(0.18), glowColor.opacity(0.0)],
            center: .top,
            startRadius: 10,
            endRadius: 340
        )
        .animation(.easeInOut(duration: 0.4), value: vm.runState)
    }

    private var confirmAlertMessage: String {
        guard let drive = vm.selectedDrive else { return "" }
        let schemeText = vm.isDDModeActive
            ? "DD-Image (Raw)"
            : "\(vm.partitionScheme.rawValue) (\(vm.isGerman ? vm.partitionScheme.targetSystemDE : vm.partitionScheme.targetSystemEN)) • \(vm.fileSystem.rawValue)"
        let sourceText: String
        if vm.bootMode == .nonBootable {
            sourceText = vm.t("Nur formatieren (nicht startfähig)", "Format only (non-bootable)")
        } else {
            sourceText = vm.isoAnalysis?.fileName ?? "-"
        }

        if vm.isGerman {
            return """
            Ziel-Laufwerk: \(drive.mediaName) (\(drive.formattedSize))
            Gerät: \(drive.deviceNode)
            Schema & System: \(schemeText)
            Quelle: \(sourceText)

            ALLE Daten auf \(drive.deviceNode) werden unwiderruflich gelöscht. Fortfahren?
            """
        } else {
            return """
            Target Drive: \(drive.mediaName) (\(drive.formattedSize))
            Device: \(drive.deviceNode)
            Scheme & System: \(schemeText)
            Source: \(sourceText)

            ALL data on \(drive.deviceNode) will be permanently erased. Continue?
            """
        }
    }
}
