import SwiftUI

struct ProgressFooterView: View {
    @ObservedObject var vm: AppViewModel

    var body: some View {
        VStack(spacing: 10) {
            // Status & Progress Bar Area
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .top, spacing: 8) {
                    statusIcon
                        .padding(.top, 2)
                    Text(statusHeadline)
                        .font(.system(size: 12.5, weight: .semibold))
                        .foregroundStyle(statusColor)
                        .lineLimit(isFailedState ? 3 : 1)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)

                    Spacer(minLength: 8)

                    if isFailedState && !vm.showLogDrawer {
                        Button {
                            withAnimation(.spring(response: 0.28, dampingFraction: 0.85)) {
                                vm.showLogDrawer = true
                            }
                        } label: {
                            Label(vm.t("Protokoll", "Log"), systemImage: "terminal")
                                .font(.system(size: 11, weight: .medium))
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }

                    if vm.isRunning {
                        if let speed = vm.speedMBps, speed > 0.1 {
                            Text(String(format: "%.1f MB/s", speed))
                                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                                .padding(.horizontal, 7)
                                .padding(.vertical, 2)
                                .background(Capsule().fill(RufusTheme.accentAmber.opacity(0.16)))
                                .foregroundStyle(RufusTheme.accentAmber)
                        }
                        Text(vm.formattedElapsed)
                            .font(.system(size: 11, weight: .medium, design: .monospaced))
                            .foregroundStyle(.secondary)
                        Text("\(Int(vm.progressFraction * 100))%")
                            .font(.system(size: 12, weight: .bold, design: .monospaced))
                            .foregroundStyle(.primary)
                            .frame(width: 38, alignment: .trailing)
                    } else if case .completed = vm.runState {
                        Text("100%  •  \(vm.formattedElapsed)")
                            .font(.system(size: 11, weight: .semibold, design: .monospaced))
                            .foregroundStyle(RufusTheme.accentGreen)
                    }
                }

                // Custom Sleek Gradient Progress Bar
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule()
                            .fill(Color.primary.opacity(0.09))
                            .frame(height: 8)

                        Capsule()
                            .fill(barGradient)
                            .frame(width: max(0, geo.size.width * CGFloat(displayFraction)), height: 8)
                            .animation(.easeOut(duration: 0.2), value: displayFraction)
                    }
                }
                .frame(height: 8)

                if !vm.currentDetail.isEmpty && (vm.isRunning || isTerminalState) {
                    Text(vm.currentDetail)
                        .font(.system(size: 10.5, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }

            // Action Row
            HStack(spacing: 10) {
                if let reason = vm.startBlockReason, !vm.isRunning {
                    HStack(spacing: 5) {
                        Image(systemName: "info.circle")
                            .font(.system(size: 11))
                        Text(reason)
                            .font(.system(size: 11))
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                    .foregroundStyle(.secondary)
                }

                Spacer()

                if vm.isRunning {
                    Button {
                        vm.cancelFlash()
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "stop.fill")
                                .font(.system(size: 11, weight: .bold))
                            Text(vm.t("ABBRECHEN", "CANCEL"))
                                .font(.system(size: 13, weight: .bold, design: .rounded))
                        }
                        .foregroundStyle(.white)
                        .padding(.horizontal, 22)
                        .padding(.vertical, 9)
                        .background(
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .fill(RufusTheme.accentRed)
                                .shadow(color: RufusTheme.accentRed.opacity(0.3), radius: 6, x: 0, y: 2)
                        )
                    }
                    .buttonStyle(.plain)
                } else {
                    Button {
                        vm.requestStart()
                    } label: {
                        HStack(spacing: 7) {
                            Image(systemName: "bolt.fill")
                                .font(.system(size: 12, weight: .bold))
                            Text(vm.t("START", "START"))
                                .font(.system(size: 13.5, weight: .bold, design: .rounded))
                        }
                        .foregroundStyle(.white)
                        .padding(.horizontal, 28)
                        .padding(.vertical, 9)
                        .background(
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .fill(vm.canStart ? RufusTheme.primaryGradient : LinearGradient(colors: [Color.gray.opacity(0.45)], startPoint: .leading, endPoint: .trailing))
                                .shadow(color: vm.canStart ? RufusTheme.accentBlue.opacity(0.35) : .clear, radius: 8, x: 0, y: 3)
                        )
                    }
                    .buttonStyle(.plain)
                    .disabled(!vm.canStart)
                }
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
        .background(.ultraThinMaterial)
        .overlay(alignment: .top) {
            Divider().opacity(0.6)
        }
    }

    private var isTerminalState: Bool {
        switch vm.runState {
        case .completed, .cancelled, .failed: return true
        default: return false
        }
    }

    private var isFailedState: Bool {
        if case .failed = vm.runState { return true }
        return false
    }

    private var displayFraction: Double {
        switch vm.runState {
        case .idle: return 0
        case .running: return max(0.02, vm.progressFraction)
        case .completed: return 1.0
        case .cancelled, .failed: return vm.progressFraction
        }
    }

    private var barGradient: LinearGradient {
        switch vm.runState {
        case .running: return RufusTheme.flashGradient
        case .completed: return RufusTheme.successGradient
        case .failed: return LinearGradient(colors: [RufusTheme.accentRed], startPoint: .leading, endPoint: .trailing)
        case .cancelled: return LinearGradient(colors: [RufusTheme.accentAmber], startPoint: .leading, endPoint: .trailing)
        case .idle: return RufusTheme.primaryGradient
        }
    }

    private var statusColor: Color {
        switch vm.runState {
        case .idle: return .secondary
        case .running: return .primary
        case .completed: return RufusTheme.accentGreen
        case .cancelled: return RufusTheme.accentAmber
        case .failed: return RufusTheme.accentRed
        }
    }

    private var statusHeadline: String {
        switch vm.runState {
        case .idle:
            return vm.t("BEREIT", "READY")
        case .running:
            return vm.currentStage.isEmpty ? vm.t("Arbeite…", "Working…") : vm.currentStage
        case .completed(let msg):
            return msg
        case .cancelled:
            return vm.currentStage.isEmpty ? vm.t("Abgebrochen", "Cancelled") : vm.currentStage
        case .failed(let err):
            return err
        }
    }

    @ViewBuilder
    private var statusIcon: some View {
        switch vm.runState {
        case .idle:
            Circle().fill(RufusTheme.accentGreen).frame(width: 8, height: 8)
        case .running:
            ProgressView().controlSize(.mini)
        case .completed:
            Image(systemName: "checkmark.circle.fill").foregroundStyle(RufusTheme.accentGreen)
        case .cancelled:
            Image(systemName: "exclamationmark.circle.fill").foregroundStyle(RufusTheme.accentAmber)
        case .failed:
            Image(systemName: "xmark.octagon.fill").foregroundStyle(RufusTheme.accentRed)
        }
    }
}
