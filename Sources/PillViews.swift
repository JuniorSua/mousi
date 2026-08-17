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
            case .working(let label):
                WorkingPill(label: label)
            case .done(let verb):
                DonePill(verb: verb)
            case .note(let title, let body):
                NoteCard(controller: controller, title: title, body: body)
            case .error(let msg):
                ErrorCard(message: msg)
            }
        }
        .padding(12) // room for the soft shadow inside the transparent panel
        .fixedSize()
    }
}

// MARK: - Design tokens

private enum UI {
    static let label = Font.system(size: 12, weight: .medium)
    static let body = Font.system(size: 12)
    static let title = Font.system(size: 12, weight: .semibold)
    static let control: CGFloat = 18   // icon/label line height
    static let radius: CGFloat = 16
}

/// One Liquid Glass surface — only the outermost container, per Apple's guidance.
private struct GlassSurface<S: Shape>: ViewModifier {
    let shape: S
    var interactive = false
    func body(content: Content) -> some View {
        content
            .glassEffect(interactive ? .regular.interactive() : .regular, in: shape)
            .shadow(color: .black.opacity(0.13), radius: 11, y: 5)
    }
}

private extension View {
    func glassSurface<S: Shape>(_ shape: S, interactive: Bool = false) -> some View {
        modifier(GlassSurface(shape: shape, interactive: interactive))
    }
}

private struct PillButtonStyle: ButtonStyle {
    var tint: Color = .primary
    var filled = false
    @State private var hovering = false
    func makeBody(configuration: Configuration) -> some View {
        let bg: Double = configuration.isPressed ? 0.18 : (hovering ? 0.11 : (filled ? 0.07 : 0))
        return configuration.label
            .foregroundStyle(tint)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Capsule(style: .continuous).fill(Color.primary.opacity(bg)))
            .contentShape(Capsule(style: .continuous))
            .onHover { hovering = $0 }
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
            .animation(.spring(duration: 0.16), value: hovering)
            .animation(.spring(duration: 0.16), value: configuration.isPressed)
    }
}

// MARK: - Compact pill (the thing you see on every selection)

private struct CompactPill: View {
    @ObservedObject var controller: PillController

    var body: some View {
        HStack(spacing: 1) {
            Button(action: controller.copyOriginal) {
                Image(systemName: "doc.on.doc")
                    .font(.system(size: 12, weight: .semibold))
                    .frame(width: UI.control, height: UI.control)
            }
            .buttonStyle(PillButtonStyle())
            .help("Copy selection")

            Divider().frame(height: 14).opacity(0.5).padding(.horizontal, 2)

            ActionButton(action: Actions.professional, controller: controller, primary: true)
            ActionButton(action: Actions.friendly, controller: controller, primary: false)

            Divider().frame(height: 14).opacity(0.5).padding(.horizontal, 2)

            MoreMenu(controller: controller)
        }
        .padding(3)
        .glassSurface(Capsule(style: .continuous), interactive: true)
    }
}

private struct ActionButton: View {
    let action: MousiAction
    @ObservedObject var controller: PillController
    let primary: Bool

    var body: some View {
        Button { controller.perform(action) } label: {
            HStack(spacing: 4) {
                if primary {
                    Image(systemName: action.icon)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Color.accentColor)
                }
                Text(action.label).font(UI.label)
            }
            .frame(height: UI.control)
        }
        .buttonStyle(PillButtonStyle(filled: primary))
        .help(action.hint + "  (hold ⌥ to copy instead)")
    }
}

private struct MoreMenu: View {
    @ObservedObject var controller: PillController
    @State private var hovering = false

    var body: some View {
        Menu {
            ForEach(Actions.more) { a in
                Button { controller.perform(a) } label: { Label(a.label, systemImage: a.icon) }
            }
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.primary)
                .frame(width: UI.control, height: UI.control)
                .padding(.horizontal, 6)
                .padding(.vertical, 4)
                .background(Capsule(style: .continuous).fill(Color.primary.opacity(hovering ? 0.11 : 0)))
                .contentShape(Capsule(style: .continuous))
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .onHover { hovering = $0 }
        .help("More actions")
    }
}

// MARK: - Transient states

private struct WorkingPill: View {
    let label: String
    var body: some View {
        HStack(spacing: 7) {
            ProgressView().controlSize(.small).scaleEffect(0.8)
            Text(label).font(UI.label).foregroundStyle(.primary)
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 6)
        .glassSurface(Capsule(style: .continuous))
        .transition(.opacity)
    }
}

private struct DonePill: View {
    let verb: String
    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
            Text(verb).font(UI.label).foregroundStyle(.primary)
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 6)
        .glassSurface(Capsule(style: .continuous))
        .transition(.opacity)
    }
}

private struct ErrorCard: View {
    let message: String
    var body: some View {
        HStack(alignment: .top, spacing: 7) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            Text(message).font(UI.body).foregroundStyle(.primary).lineLimit(4)
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 9)
        .frame(maxWidth: 300, alignment: .leading)
        .glassSurface(RoundedRectangle(cornerRadius: UI.radius, style: .continuous))
    }
}

/// For actions that report back instead of rewriting (the pre-send check).
private struct NoteCard: View {
    @ObservedObject var controller: PillController
    let title: String
    let body_: String

    init(controller: PillController, title: String, body: String) {
        self.controller = controller
        self.title = title
        self.body_ = body
    }

    private var isClean: Bool { body_.lowercased().hasPrefix("looks good") }

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 6) {
                Image(systemName: isClean ? "checkmark.seal.fill" : "shield.lefthalf.filled")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(isClean ? .green : .orange)
                Text(title).font(UI.title).foregroundStyle(.primary)
                Spacer(minLength: 12)
                Button(action: controller.hide) {
                    Image(systemName: "xmark").font(.system(size: 9, weight: .bold))
                        .frame(width: 16, height: 16)
                }
                .buttonStyle(PillButtonStyle())
            }
            Text(body_)
                .font(UI.body)
                .foregroundStyle(.primary)
                .lineSpacing(2)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
        }
        .padding(11)
        .frame(width: 320, alignment: .leading)
        .glassSurface(RoundedRectangle(cornerRadius: UI.radius, style: .continuous))
    }
}
