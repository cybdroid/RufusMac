import SwiftUI

struct HeaderView: View {
    @ObservedObject var vm: AppViewModel

    var body: some View {
        HStack(spacing: 12) {
            // Custom layered brand mark
            ZStack {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(RufusTheme.brandIconGradient)
                    .frame(width: 40, height: 40)
                    .shadow(color: RufusTheme.accentBlue.opacity(0.35), radius: 8, x: 0, y: 3)

                Image(systemName: "externaldrive.fill.badge.bolt")
                    .font(.system(size: 18, weight: .bold))
                    .foregroundStyle(.white)
            }

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 7) {
                    Text("RufusMac")
                        .font(.system(size: 18, weight: .bold, design: .rounded))
                        .foregroundStyle(.primary)

                    Text("x86_64")
                        .font(.system(size: 10, weight: .semibold, design: .monospaced))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(RufusTheme.accentBlue.opacity(0.16)))
                        .foregroundStyle(RufusTheme.accentBlue)
                }

                Text(vm.t("Bootfähige Windows & Linux USB-Medien für macOS", "Bootable Windows & Linux USB Media for macOS"))
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
            }

            Spacer()

            HStack(spacing: 6) {
                // DE / EN toggle
                Button {
                    withAnimation(.easeInOut(duration: 0.15)) {
                        vm.isGerman.toggle()
                    }
                } label: {
                    Text(vm.isGerman ? "DE" : "EN")
                        .font(.system(size: 11, weight: .semibold, design: .rounded))
                        .frame(width: 28, height: 26)
                        .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(.quaternary))
                }
                .buttonStyle(.plain)
                .help(vm.t("Sprache wechseln (Deutsch / Englisch)", "Switch language (German / English)"))

                // Checksum inspector
                if vm.isoAnalysis != nil {
                    Button {
                        vm.showChecksumSheet = true
                    } label: {
                        Image(systemName: "number.square")
                            .font(.system(size: 13, weight: .medium))
                            .frame(width: 28, height: 26)
                            .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(.quaternary))
                    }
                    .buttonStyle(.plain)
                    .help(vm.t("ISO-Prüfsummen berechnen (MD5 / SHA-1 / SHA-256)", "Compute ISO Checksums (MD5 / SHA-1 / SHA-256)"))
                }

                // Log drawer toggle
                Button {
                    withAnimation(.spring(response: 0.28, dampingFraction: 0.85)) {
                        vm.showLogDrawer.toggle()
                    }
                } label: {
                    Image(systemName: vm.showLogDrawer ? "terminal.fill" : "terminal")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(vm.showLogDrawer ? RufusTheme.accentBlue : .primary)
                        .frame(width: 28, height: 26)
                        .background(
                            RoundedRectangle(cornerRadius: 7, style: .continuous)
                                .fill(vm.showLogDrawer ? RufusTheme.accentBlue.opacity(0.16) : Color.primary.opacity(0.06))
                        )
                }
                .buttonStyle(.plain)
                .help(vm.t("Protokoll anzeigen / ausblenden", "Show / hide live log"))
            }
        }
        .padding(.horizontal, 18)
        .padding(.top, 14)
        .padding(.bottom, 10)
    }
}
