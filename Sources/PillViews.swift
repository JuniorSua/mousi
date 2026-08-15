import SwiftUI

// MARK: - Root

struct PillRootView: View {
    let controller: PillController?

    var body: some View {
        if let c = controller {
            PillContent(controller: c)
        } else {
            EmptyView()
        }
    }
}

private struct PillContent: View {
    @ObservedObject var controller: PillController

    var body: some View {
        Group {
            switch controller.phase {
            case .compact:
                CompactPill(controller: controller)
            case .copied:
                StatusPill(icon: "checkmark.circle.fill", tint: .green, text: "Copied")
            case .loading:
                LoadingPill()
            case .results(let r):
                ResultsCard(controller: controller, rewrites: r)
            case .prompt(let p):
                PromptCard(controller: controller, prompt: p)
            case .error(let msg):
                ErrorCard(message: msg)
            }
        }
        .padding(18) // breathing room for the glass shadow inside the transparent panel
        .fixedSize()
    }
}

// MARK: - Design tokens

private enum UI {
    static let body = Font.system(size: 13)
    static let bodyMedium = Font.system(size: 13, weight: .medium)
    static let title = Font.system(size: 13, weight: .semibold)
    static let tag = Font.system(size: 10, weight: .bold)
    static let cardRadius: CGFloat = 22
    static let rowRadius: CGFloat = 14
    static let cardWidth: CGFloat = 360
}

/// One Liquid Glass surface. Only the outermost container gets glass — content inside is
/// plain, per Apple's guidance not to stack glass on glass.
private struct GlassSurface<S: Shape>: ViewModifier {
    let shape: S
    var interactive = false
    func body(content: Content) -> some View {
        content
            .glassEffect(interactive ? .regular.interactive() : .regular, in: shape)
            .shadow(color: .black.opacity(0.14), radius: 14, y: 6)
    }
}

private extension View {
    func glassSurface<S: Shape>(_ shape: S, interactive: Bool = false) -> some View {
        modifier(GlassSurface(shape: shape, interactive: interactive))
    }
}

/// Text-and-icon button used inside glass. Highlights on hover, presses with a gentle scale.
private struct InlineButtonStyle: ButtonStyle {
    var tint: Color = .primary
    var prominent = false
    @State private var hovering = false
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(tint)
            .padding(.horizontal, prominent ? 10 : 8)
            .padding(.vertical, 6)
            .background(
                Capsule(style: .continuous)
                    .fill(Color.primary.opacity(configuration.isPressed ? 0.16 : (hovering ? 0.10 : 0)))
            )
            .contentShape(Capsule(style: .continuous))
            .onHover { hovering = $0 }
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
            .animation(.spring(duration: 0.18), value: hovering)
            .animation(.spring(duration: 0.18), value: configuration.isPressed)
    }
}

private struct RoundButtonStyle: ButtonStyle {
    @State private var hovering = false
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(.primary)
            .frame(width: 24, height: 24)
            .background(Circle().fill(Color.primary.opacity(configuration.isPressed ? 0.16 : (hovering ? 0.10 : 0.05))))
            .contentShape(Circle())
            .onHover { hovering = $0 }
            .animation(.spring(duration: 0.18), value: hovering)
    }
}

// MARK: - Compact pill

private struct CompactPill: View {
    @ObservedObject var controller: PillController

    var body: some View {
        HStack(spacing: 2) {
            Button(action: controller.copyOriginal) {
                Image(systemName: "doc.on.doc")
                    .font(.system(size: 13, weight: .semibold))
                    .frame(width: 20, height: 20)
            }
            .buttonStyle(InlineButtonStyle())
            .help("Copy selection")

            Separator()

            Button(action: controller.rewrite) {
                HStack(spacing: 5) {
                    Image(systemName: "wand.and.sparkles")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Color.accentColor)
                    Text("Rewrite").font(UI.bodyMedium)
                }
                .frame(height: 20)
            }
            .buttonStyle(InlineButtonStyle(prominent: true))
            .help("Fix grammar and get tone options")

            Separator()

            Button(action: controller.enhancePrompt) {
                HStack(spacing: 5) {
                    Image(systemName: "lightbulb.max.fill")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.purple)
                    Text("Prompt").font(UI.bodyMedium)
                }
                .frame(height: 20)
            }
            .buttonStyle(InlineButtonStyle(prominent: true))
            .help("Turn this into a well-engineered AI prompt")
        }
        .padding(4)
        .glassSurface(Capsule(style: .continuous), interactive: true)
    }
}

private struct Separator: View {
    var body: some View {
        Rectangle()
            .fill(Color.primary.opacity(0.14))
            .frame(width: 1, height: 16)
            .padding(.horizontal, 2)
    }
}

private struct StatusPill: View {
    let icon: String
    let tint: Color
    let text: String
    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: icon).foregroundStyle(tint)
            Text(text).foregroundStyle(.primary)
        }
        .font(UI.bodyMedium)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .glassSurface(Capsule(style: .continuous))
    }
}

private struct LoadingPill: View {
    var body: some View {
        HStack(spacing: 8) {
            ProgressView().controlSize(.small)
            Text("Thinking…").font(UI.bodyMedium).foregroundStyle(.primary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .glassSurface(Capsule(style: .continuous))
    }
}

private struct ErrorCard: View {
    let message: String
    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            Text(message)
                .font(UI.body)
                .foregroundStyle(.primary)
                .lineLimit(4)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(maxWidth: 320, alignment: .leading)
        .glassSurface(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}

// MARK: - Card chrome shared by Rewrite and Prompt

private struct CardHeader: View {
    let icon: String
    let iconTint: Color
    let title: String
    @ObservedObject var controller: PillController

    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: icon)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(iconTint)
            Text(title)
                .font(UI.title)
                .foregroundStyle(.primary)
            Spacer()
            if let f = controller.flash {
                HStack(spacing: 4) {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                    Text(f).foregroundStyle(.primary)
                }
                .font(.system(size: 11, weight: .medium))
                .transition(.opacity)
            }
            Button(action: controller.hide) {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .bold))
            }
            .buttonStyle(RoundButtonStyle())
            .help("Dismiss")
        }
        .padding(.leading, 4)
    }
}

// MARK: - Rewrite results

private struct ResultsCard: View {
    @ObservedObject var controller: PillController
    let rewrites: Rewrites

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            CardHeader(icon: "wand.and.sparkles", iconTint: .accentColor, title: "Rewrite", controller: controller)
                .padding(.bottom, 2)
            ResultRow(label: "Fixed", tint: .green, text: rewrites.corrected, controller: controller)
            ResultRow(label: "Professional", tint: .blue, text: rewrites.professional, controller: controller)
            ResultRow(label: "Friendly", tint: .orange, text: rewrites.friendly, controller: controller)
        }
        .padding(10)
        .frame(width: UI.cardWidth)
        .glassSurface(RoundedRectangle(cornerRadius: UI.cardRadius, style: .continuous))
    }
}

private struct ResultRow: View {
    let label: String
    let tint: Color
    let text: String
    @ObservedObject var controller: PillController
    @State private var hovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text(label.uppercased())
                    .font(UI.tag)
                    .tracking(0.5)
                    .foregroundStyle(tint)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(tint.opacity(0.18), in: Capsule())
                Spacer()
                HStack(spacing: 2) {
                    Button { controller.copy(text) } label: {
                        Label("Copy", systemImage: "doc.on.doc")
                            .font(.system(size: 11, weight: .medium))
                    }
                    .buttonStyle(InlineButtonStyle())
                    .help("Copy this version")
                    Button { controller.replace(text) } label: {
                        Label("Replace", systemImage: "arrow.left.arrow.right")
                            .font(.system(size: 11, weight: .medium))
                    }
                    .buttonStyle(InlineButtonStyle())
                    .help("Replace the highlighted text with this version")
                }
                .labelStyle(.titleAndIcon)
                .opacity(hovering ? 1 : 0.85)
            }
            Text(text)
                .font(UI.body)
                .foregroundStyle(.primary)
                .lineSpacing(1.5)
                .lineLimit(6)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: UI.rowRadius, style: .continuous)
                .fill(Color.primary.opacity(hovering ? 0.10 : 0.06))
        )
        .contentShape(RoundedRectangle(cornerRadius: UI.rowRadius, style: .continuous))
        .onHover { hovering = $0 }
        .onTapGesture { controller.copy(text) }
        .animation(.spring(duration: 0.18), value: hovering)
    }
}

// MARK: - Prompt result

private struct PromptCard: View {
    @ObservedObject var controller: PillController
    let prompt: String

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            CardHeader(icon: "lightbulb.max.fill", iconTint: .purple, title: "Enhanced prompt", controller: controller)
            ScrollView {
                Text(prompt)
                    .font(UI.body)
                    .foregroundStyle(.primary)
                    .lineSpacing(2)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
            }
            .frame(maxHeight: 300)
            .background(
                RoundedRectangle(cornerRadius: UI.rowRadius, style: .continuous)
                    .fill(Color.primary.opacity(0.06))
            )
            HStack(spacing: 8) {
                Spacer()
                Button { controller.copy(prompt) } label: {
                    Label("Copy", systemImage: "doc.on.doc")
                }
                .buttonStyle(.bordered)
                Button { controller.replace(prompt) } label: {
                    Label("Replace", systemImage: "arrow.left.arrow.right")
                }
                .buttonStyle(.borderedProminent)
                .tint(.purple)
            }
            .controlSize(.regular)
            .font(.system(size: 12, weight: .medium))
        }
        .padding(12)
        .frame(width: UI.cardWidth + 30)
        .glassSurface(RoundedRectangle(cornerRadius: UI.cardRadius, style: .continuous))
    }
}
