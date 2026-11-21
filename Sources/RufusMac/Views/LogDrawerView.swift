import SwiftUI

struct LogDrawerView: View {
    @ObservedObject var vm: AppViewModel

    private static let timeFormatter: DateFormatter = {
        let df = DateFormatter()
        df.dateFormat = "HH:mm:ss"
        return df
    }()

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Image(systemName: "terminal.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(RufusTheme.accentBlue)
                Text(vm.t("Live-Protokoll", "Live Log"))
                    .font(.system(size: 12, weight: .semibold))
                Spacer()
                Button {
                    vm.copyLogsToPasteboard()
                } label: {
                    Label(vm.t("Kopieren", "Copy"), systemImage: "doc.on.doc")
                        .font(.system(size: 11))
                }
                .buttonStyle(.borderless)

                Button {
                    vm.logs.removeAll()
                } label: {
                    Label(vm.t("Leeren", "Clear"), systemImage: "trash")
                        .font(.system(size: 11))
                }
                .buttonStyle(.borderless)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(Color.primary.opacity(0.04))

            Divider().opacity(0.5)

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 3) {
                        ForEach(vm.logs) { entry in
                            HStack(alignment: .top, spacing: 7) {
                                Text(Self.timeFormatter.string(from: entry.timestamp))
                                    .font(.system(size: 10.5, design: .monospaced))
                                    .foregroundStyle(.secondary)
                                Text(entry.text)
                                    .font(.system(size: 11, design: .monospaced))
                                    .foregroundStyle(color(for: entry.level))
                                    .textSelection(.enabled)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .id(entry.id)
                        }
                    }
                    .padding(10)
                }
                .frame(height: 155)
                .background(Color(nsColor: .textBackgroundColor).opacity(0.55))
                .onChange(of: vm.logs.count) { _ in
                    if let last = vm.logs.last {
                        withAnimation(.easeOut(duration: 0.15)) {
                            proxy.scrollTo(last.id, anchor: .bottom)
                        }
                    }
                }
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.10), lineWidth: 1)
        )
    }

    private func color(for level: LogEntry.Level) -> Color {
        switch level {
        case .info: return .primary
        case .stage: return RufusTheme.accentBlue
        case .success: return RufusTheme.accentGreen
        case .warning: return RufusTheme.accentAmber
        case .error: return RufusTheme.accentRed
        }
    }
}
