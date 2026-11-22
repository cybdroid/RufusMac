import SwiftUI

struct WindowsOptionsView: View {
    @ObservedObject var vm: AppViewModel

    var body: some View {
        SectionCard(
            title: vm.t("Windows-Anpassungen (Rufus-Modus)", "Windows Customization (Rufus Mode)"),
            icon: "wand.and.stars",
            iconColor: RufusTheme.accentBlue,
            trailing: {
                if vm.windowsOptions.isAnyEnabled {
                    StatusPill(
                        vm.windowsOptions.bypassHardwareChecks ? "autounattend.xml" : "Panther/unattend.xml",
                        icon: "doc.badge.gearshape.fill",
                        color: RufusTheme.accentBlue
                    )
                }
            }
        ) {
            VStack(alignment: .leading, spacing: 9) {
                Toggle(isOn: $vm.windowsOptions.bypassHardwareChecks) {
                    VStack(alignment: .leading, spacing: 1) {
                        HStack(spacing: 6) {
                            Text(vm.t("TPM 2.0, Secure Boot & 4 GB RAM-Prüfung entfernen", "Remove requirement for 4GB+ RAM, Secure Boot and TPM 2.0"))
                                .font(.system(size: 12, weight: .medium))
                            if vm.isoAnalysis?.isWindows11Likely == false {
                                Text(vm.t("Nur Win 11", "Win 11 only"))
                                    .font(.system(size: 9.5, weight: .semibold))
                                    .padding(.horizontal, 5)
                                    .padding(.vertical, 1.5)
                                    .background(Capsule().fill(Color.secondary.opacity(0.16)))
                                    .foregroundStyle(.secondary)
                            }
                        }
                        Text(vm.t("Ermöglicht Windows 11 Installation auf älterer Hardware (LabConfig + ProductKey-Safe).", "Allows installing Windows 11 on unsupported hardware (LabConfig + ProductKey-Safe)."))
                            .font(.system(size: 10.5))
                            .foregroundStyle(.secondary)
                    }
                }
                .toggleStyle(.checkbox)

                Toggle(isOn: $vm.windowsOptions.bypassMicrosoftAccount) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(vm.t("Microsoft-Konto-Zwang entfernen (Lokales Konto erstellen)", "Remove requirement for an online Microsoft account (Local Account)"))
                            .font(.system(size: 12, weight: .medium))
                        Text(vm.t("Überspringt Online-Anmeldung (BypassNRO) und legt ein lokales Admin-Konto an.", "Skips online sign-in (BypassNRO) and creates a local admin user."))
                            .font(.system(size: 10.5))
                            .foregroundStyle(.secondary)
                    }
                }
                .toggleStyle(.checkbox)

                if vm.windowsOptions.bypassMicrosoftAccount {
                    HStack(spacing: 8) {
                        Text(vm.t("Lokaler Benutzername:", "Local username:"))
                            .font(.system(size: 11.5))
                            .foregroundStyle(.secondary)
                        TextField("User", text: $vm.windowsOptions.localAccountUsername)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 170)
                    }
                    .padding(.leading, 22)
                }

                Toggle(isOn: $vm.windowsOptions.disablePrivacyQuestions) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(vm.t("Datenschutz-Fragen & EULA im Setup überspringen", "Disable data collection & skip privacy questions"))
                            .font(.system(size: 12, weight: .medium))
                        Text(vm.t("Setzt ProtectYourPC=3 und überspringt Lizenz-Bestätigung.", "Sets ProtectYourPC=3 and skips EULA page."))
                            .font(.system(size: 10.5))
                            .foregroundStyle(.secondary)
                    }
                }
                .toggleStyle(.checkbox)
            }
            .disabled(vm.isRunning)
        }
    }
}
