import SwiftUI
import AppKit

struct ChecksumSheetView: View {
    @ObservedObject var vm: AppViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var expectedHash: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Image(systemName: "checkmark.seal.fill")
                    .font(.system(size: 18))
                    .foregroundStyle(RufusTheme.accentBlue)
                VStack(alignment: .leading, spacing: 2) {
                    Text(vm.t("ISO-Prüfsummen", "ISO Checksums"))
                        .font(.system(size: 15, weight: .bold))
                    if let name = vm.isoAnalysis?.fileName {
                        Text(name)
                            .font(.system(size: 11.5))
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
                Button(vm.t("Schließen", "Close")) { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }

            Divider()

            if vm.isComputingChecksums {
                VStack(spacing: 10) {
                    ProgressView(value: vm.checksumProgress)
                        .progressViewStyle(.linear)
                    Text(vm.t(
                        "Berechne MD5, SHA-1 und SHA-256… (\(Int(vm.checksumProgress * 100))%)",
                        "Computing MD5, SHA-1 and SHA-256… (\(Int(vm.checksumProgress * 100))%)"
                    ))
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                }
                .padding(.vertical, 16)
            } else if let hashes = vm.computedChecksums {
                VStack(alignment: .leading, spacing: 10) {
                    hashRow("MD5", value: hashes.md5)
                    hashRow("SHA-1", value: hashes.sha1)
                    hashRow("SHA-256", value: hashes.sha256)

                    Divider()

                    VStack(alignment: .leading, spacing: 6) {
                        Text(vm.t("Prüfsumme vergleichen (optional):", "Compare against expected hash (optional):"))
                            .font(.system(size: 11.5, weight: .medium))
                            .foregroundStyle(.secondary)
                        TextField(vm.t("Erwarteten MD5 / SHA-1 / SHA-256 Hash einfügen…", "Paste expected MD5 / SHA-1 / SHA-256 hash…"), text: $expectedHash)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(size: 11.5, design: .monospaced))

                        let clean = expectedHash.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                        if !clean.isEmpty {
                            let matches = clean == hashes.md5 || clean == hashes.sha1 || clean == hashes.sha256
                            HStack(spacing: 6) {
                                Image(systemName: matches ? "checkmark.circle.fill" : "xmark.circle.fill")
                                Text(matches
                                    ? vm.t("Prüfsumme stimmt exakt überein!", "Checksum matches exactly!")
                                    : vm.t("Prüfsumme stimmt NICHT überein.", "Checksum does NOT match."))
                            }
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(matches ? RufusTheme.accentGreen : RufusTheme.accentRed)
                        }
                    }
                }
            } else if let err = vm.checksumError {
                Text(err)
                    .foregroundStyle(RufusTheme.accentRed)
                    .font(.system(size: 12))
            } else {
                HStack {
                    Text(vm.t("Berechnet MD5, SHA-1 und SHA-256 in einem Durchgang.", "Computes MD5, SHA-1 and SHA-256 in a single pass."))
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button(vm.t("Berechnen", "Compute")) {
                        vm.computeChecksums()
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
        }
        .padding(18)
        .frame(width: 520)
        .onAppear {
            if vm.computedChecksums == nil && !vm.isComputingChecksums {
                vm.computeChecksums()
            }
        }
    }

    private func hashRow(_ label: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(label)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(value, forType: .string)
                } label: {
                    Label(vm.t("Kopieren", "Copy"), systemImage: "doc.on.doc")
                        .font(.system(size: 10.5))
                }
                .buttonStyle(.borderless)
            }
            Text(value)
                .font(.system(size: 11, design: .monospaced))
                .textSelection(.enabled)
                .padding(7)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 7).fill(Color.primary.opacity(0.05)))
        }
    }
}
