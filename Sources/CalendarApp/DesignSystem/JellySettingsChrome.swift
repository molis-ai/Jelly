import SwiftUI

struct JellySettingsPage<Content: View>: View {
    @Environment(\.colorScheme) private var colorScheme
    @ViewBuilder var content: () -> Content

    private var theme: CalendarSemanticAppearance {
        CalendarTheme.appearance(for: colorScheme)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                content()
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(theme.canvas)
        .foregroundStyle(theme.primaryText)
        .tint(theme.controlAccent)
        .toolbarBackground(theme.canvas, for: .windowToolbar)
    }
}

struct JellySettingsCard<Content: View>: View {
    @Environment(\.colorScheme) private var colorScheme
    @ViewBuilder var content: () -> Content

    private var theme: CalendarSemanticAppearance {
        CalendarTheme.appearance(for: colorScheme)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12, content: content)
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                theme.elevatedSurface,
                in: RoundedRectangle(cornerRadius: 12, style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(theme.subtleBorder.opacity(0.55), lineWidth: 0.5)
            }
    }
}

struct JellyChoicePicker: View {
    let options: [(id: String, title: String)]
    @Binding var selection: String
    @Environment(\.colorScheme) private var colorScheme

    private var theme: CalendarSemanticAppearance {
        CalendarTheme.appearance(for: colorScheme)
    }

    var body: some View {
        HStack(spacing: 6) {
            ForEach(options, id: \.id) { option in
                let selected = option.id == selection
                Button {
                    selection = option.id
                } label: {
                    Text(option.title)
                        .font(.system(size: 12, weight: selected ? .semibold : .regular))
                        .foregroundStyle(selected ? theme.primaryText : theme.secondaryText)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 7)
                        .background(
                            selected ? theme.selectionFill : Color.clear,
                            in: RoundedRectangle(cornerRadius: 8, style: .continuous)
                        )
                        .overlay {
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .stroke(
                                    selected ? theme.controlAccent.opacity(0.55) : theme.subtleBorder.opacity(0.45),
                                    lineWidth: 0.5
                                )
                        }
                }
                .buttonStyle(.plain)
            }
        }
    }
}

struct JellySettingsField: View {
    let title: String
    @Binding var text: String
    var secure = false
    @Environment(\.colorScheme) private var colorScheme

    private var theme: CalendarSemanticAppearance {
        CalendarTheme.appearance(for: colorScheme)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.system(size: 12))
                .foregroundStyle(theme.secondaryText)
            Group {
                if secure {
                    SecureField("", text: $text)
                } else {
                    TextField("", text: $text)
                }
            }
            .textFieldStyle(.plain)
            .font(.system(size: 13))
            .padding(.horizontal, 10)
            .frame(height: 32)
            .background(
                theme.canvas,
                in: RoundedRectangle(cornerRadius: CalendarTheme.cornerRadius, style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: CalendarTheme.cornerRadius, style: .continuous)
                    .stroke(theme.subtleBorder.opacity(0.7), lineWidth: 0.5)
            }
        }
    }
}
