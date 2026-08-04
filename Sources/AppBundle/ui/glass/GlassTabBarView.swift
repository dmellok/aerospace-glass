import AppKit
import SwiftUI

struct GlassTabItem: Identifiable {
    let id: UInt32 // windowId
    let title: String
    let icon: NSImage?
    let isActive: Bool
}

struct GlassTabBarView: View {
    var items: [GlassTabItem]
    var cornerRadius: CGFloat
    var fontSize: CGFloat
    var showIcons: Bool
    var activeTint: Color
    var onSelect: (UInt32) -> Void

    var body: some View {
        Group {
            if #available(macOS 26.0, *) {
                GlassEffectContainer(spacing: 6) {
                    strip
                }
            } else {
                strip
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var strip: some View {
        HStack(spacing: 6) {
            ForEach(items) { item in
                GlassTabView(
                    item: item,
                    cornerRadius: cornerRadius,
                    fontSize: fontSize,
                    showIcons: showIcons,
                    activeTint: activeTint,
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .contentShape(Rectangle())
                .onTapGesture { onSelect(item.id) }
            }
        }
    }
}

private struct GlassTabView: View {
    var item: GlassTabItem
    var cornerRadius: CGFloat
    var fontSize: CGFloat
    var showIcons: Bool
    var activeTint: Color

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
    }

    var body: some View {
        content
            .padding(.horizontal, 8)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .modifier(GlassTabBackground(
                shape: shape,
                tint: item.isActive ? activeTint : nil,
            ))
    }

    private var content: some View {
        HStack(spacing: 5) {
            if showIcons, let icon = item.icon {
                Image(nsImage: icon)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: fontSize + 3, height: fontSize + 3)
            }
            Text(item.title)
                .font(.system(size: fontSize, weight: item.isActive ? .semibold : .regular))
                .lineLimit(1)
                .truncationMode(.tail)
                .foregroundStyle(item.isActive ? .primary : .secondary)
        }
    }
}

private struct GlassTabBackground<S: Shape>: ViewModifier {
    var shape: S
    var tint: Color?

    func body(content: Content) -> some View {
        if #available(macOS 26.0, *) {
            content.glassEffect(
                tint.map { Glass.regular.tint($0) } ?? .regular,
                in: shape,
            )
        } else {
            content
                .background(.ultraThinMaterial, in: shape)
                .overlay(tint.map { shape.fill($0) })
        }
    }
}
