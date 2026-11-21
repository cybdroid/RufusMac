import SwiftUI

enum RufusTheme {
    static let accentBlue = Color(red: 0.16, green: 0.52, blue: 0.99)
    static let accentCyan = Color(red: 0.14, green: 0.78, blue: 0.92)
    static let accentAmber = Color(red: 0.98, green: 0.56, blue: 0.14)
    static let accentOrange = Color(red: 0.95, green: 0.36, blue: 0.18)
    static let accentGreen = Color(red: 0.18, green: 0.80, blue: 0.44)
    static let accentRed = Color(red: 0.94, green: 0.28, blue: 0.32)
    static let accentPurple = Color(red: 0.62, green: 0.40, blue: 0.98)

    static let primaryGradient = LinearGradient(
        colors: [accentBlue, accentCyan],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )

    static let flashGradient = LinearGradient(
        colors: [accentAmber, accentOrange],
        startPoint: .leading,
        endPoint: .trailing
    )

    static let successGradient = LinearGradient(
        colors: [accentGreen, accentCyan],
        startPoint: .leading,
        endPoint: .trailing
    )

    static let brandIconGradient = LinearGradient(
        colors: [Color(red: 0.14, green: 0.48, blue: 0.98), Color(red: 0.98, green: 0.45, blue: 0.16)],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )
}

struct SectionCard<Content: View>: View {
    let title: String
    let icon: String
    let iconColor: Color
    var trailing: AnyView? = nil
    @ViewBuilder let content: () -> Content

    init(
        title: String,
        icon: String,
        iconColor: Color = RufusTheme.accentBlue,
        @ViewBuilder content: @escaping () -> Content
    ) {
        self.title = title
        self.icon = icon
        self.iconColor = iconColor
        self.trailing = nil
        self.content = content
    }

    init<Trailing: View>(
        title: String,
        icon: String,
        iconColor: Color = RufusTheme.accentBlue,
        @ViewBuilder trailing: () -> Trailing,
        @ViewBuilder content: @escaping () -> Content
    ) {
        self.title = title
        self.icon = icon
        self.iconColor = iconColor
        self.trailing = AnyView(trailing())
        self.content = content
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                ZStack {
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(iconColor.opacity(0.16))
                        .frame(width: 24, height: 24)
                    Image(systemName: icon)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(iconColor)
                }

                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.primary)

                Spacer()

                if let trailing = trailing {
                    trailing
                }
            }

            content()
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(.regularMaterial)
                .shadow(color: Color.black.opacity(0.06), radius: 8, x: 0, y: 2)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
        )
    }
}

struct StatusPill: View {
    let text: String
    let icon: String?
    let color: Color

    init(_ text: String, icon: String? = nil, color: Color) {
        self.text = text
        self.icon = icon
        self.color = color
    }

    var body: some View {
        HStack(spacing: 4) {
            if let icon = icon {
                Image(systemName: icon)
                    .font(.system(size: 10, weight: .semibold))
            }
            Text(text)
                .font(.system(size: 11, weight: .medium))
                .lineLimit(1)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 3.5)
        .background(Capsule().fill(color.opacity(0.14)))
        .overlay(Capsule().strokeBorder(color.opacity(0.28), lineWidth: 0.75))
        .foregroundStyle(color)
    }
}
