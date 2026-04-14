import AppKit
import SwiftUI

/// 悬浮工具条：圆形选取、方形选取、表情面板
final class FloatingToolbarPanel: NSPanel {
    private let onCircle: () -> Void
    private let onRect: () -> Void
    private let onEmoji: () -> Void

    init(anchorFrame: CGRect, onCircle: @escaping () -> Void, onRect: @escaping () -> Void, onEmoji: @escaping () -> Void) {
        self.onCircle = onCircle
        self.onRect = onRect
        self.onEmoji = onEmoji

        let frame = Self.frame(for: anchorFrame)

        super.init(
            contentRect: frame,
            styleMask: [.nonactivatingPanel, .fullSizeContentView, .borderless],
            backing: .buffered,
            defer: false
        )

        isFloatingPanel = true
        worksWhenModal = true
        level = .modalPanel
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        titleVisibility = .hidden
        titlebarAppearsTransparent = true

        let host = NSHostingView(rootView: ToolbarContent(
            onCircle: { [weak self] in self?.onCircle() },
            onRect: { [weak self] in self?.onRect() },
            onEmoji: { [weak self] in self?.onEmoji() }
        ))
        host.frame = NSRect(origin: .zero, size: frame.size)
        contentView = host
    }

    func reposition(anchorFrame: CGRect) {
        let frame = Self.frame(for: anchorFrame)
        setFrame(frame, display: true)
        contentView?.frame = NSRect(origin: .zero, size: frame.size)
    }

    private static func frame(for anchorFrame: CGRect) -> CGRect {
        let width: CGFloat = 200
        let height: CGFloat = 52
        let margin: CGFloat = 12
        let originX = anchorFrame.midX - width / 2
        let minScreenY = NSScreen.screens.map(\.frame.minY).min() ?? 0
        let originY = max(minScreenY + margin, anchorFrame.minY + margin)
        return CGRect(x: originX, y: originY, width: width, height: height)
    }
}

private struct ToolbarContent: View {
    let onCircle: () -> Void
    let onRect: () -> Void
    let onEmoji: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            toolButton(systemName: "circle.dashed", accessibility: "圆形选取", action: onCircle)
            toolButton(systemName: "square.dashed", accessibility: "方形选取", action: onRect)
            toolButton(systemName: "face.smiling", accessibility: "表情与符号", action: onEmoji)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.12), lineWidth: 1)
        )
    }

    private func toolButton(systemName: String, accessibility: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 18, weight: .medium))
                .frame(width: 36, height: 36)
        }
        .buttonStyle(.plain)
        .background(Color.primary.opacity(0.06), in: Circle())
        .help(accessibility)
        .accessibilityLabel(accessibility)
    }
}
