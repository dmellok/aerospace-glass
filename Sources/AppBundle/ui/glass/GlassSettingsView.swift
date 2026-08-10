import AppKit
import SwiftUI

/// Live-editable state for the settings panel.
///
/// Every change is applied to the running config immediately, because the whole point of a theming
/// panel is watching real windows change while you drag a slider. The file on disk is only touched
/// when Save is pressed, so nothing here can quietly rewrite a config you were still deciding
/// about.
@MainActor
final class GlassSettingsModel: ObservableObject {
    @Published var glass: GlassConfig {
        didSet { apply() }
    }
    /// Set after a save or a revert, cleared by the next edit.
    @Published var status: String? = nil

    private var isApplying = false

    init() {
        glass = config.glass
    }

    private func apply() {
        guard !isApplying else { return }
        status = nil
        config.glass = glass
        // Sizes feed the layout pass, not just the overlays, so a full session is needed for a
        // taller tab bar or a wider border to actually move the windows.
        WallpaperTheme.invalidate()
        scheduleCancellableCompleteRefreshSession(.glassSettingsChanged, optimisticallyPreLayoutWorkspaces: true)
    }

    /// Re-read the config file, discarding anything the panel changed.
    func revert() {
        let (parsed, url) = readConfig()
        isApplying = true
        glass = parsed.glass
        isApplying = false
        config.glass = parsed.glass
        WallpaperTheme.invalidate()
        scheduleCancellableCompleteRefreshSession(.glassSettingsChanged, optimisticallyPreLayoutWorkspaces: true)
        status = "Reverted to \(url.lastPathComponent)"
    }

    func save() {
        do {
            let backup = try GlassConfigWriter.save(glass, to: configUrl)
            status = "Saved. Previous config kept as \(backup.lastPathComponent)"
        } catch {
            status = "\(error)"
        }
    }

    func copySnippet() {
        GlassConfigWriter.snippet(for: glass).copyToClipboard()
        status = "Copied the glass.* block to the clipboard"
    }

    /// The config as it currently is on disk, so Revert doesn't depend on the panel's own state.
    private func readConfig() -> (Config, URL) {
        let url = configUrl
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return (config, url) }
        let parsed = parseConfig(text)
        return (parsed.errors.isEmpty ? parsed.config : config, url)
    }
}

struct GlassSettingsView: View {
    @StateObject private var model = GlassSettingsModel()

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    themeSection
                    tabsSection
                    bordersSection
                    dropPreviewSection
                }
                .padding(20)
            }
            Divider()
            footer
        }
        .frame(width: 460, height: 620)
    }

    // MARK: - Sections

    private var themeSection: some View {
        Section("Theme") {
            Toggle("Sample colors from the wallpaper", isOn: $model.glass.theme.fromWallpaper)
            Picker("Palette", selection: $model.glass.theme.palette) {
                Text("Mono").tag(GlassThemePalette.mono)
                Text("Multi").tag(GlassThemePalette.multi)
            }
            .pickerStyle(.segmented)
            .disabled(!model.glass.theme.fromWallpaper)
            Text(model.glass.theme.fromWallpaper
                ? "The palette owns the tints and the accent. Colors below are ignored while this is on."
                : "Colors below are used as written.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var tabsSection: some View {
        Section("Tab bars") {
            Toggle("Draw tab bars", isOn: $model.glass.tabs.enabled)
            Picker("Style", selection: $model.glass.tabs.style) {
                Text("Glass").tag(GlassTabsStyle.glass)
                Text("Flat").tag(GlassTabsStyle.flat)
            }
            .pickerStyle(.segmented)
            Toggle("Show app icons", isOn: $model.glass.tabs.showIcons)
            Toggle("Fixed-width tabs", isOn: $model.glass.tabs.fixedWidth)
            points("Tab width", $model.glass.tabs.width, 60 ... 500)
                .disabled(!model.glass.tabs.fixedWidth)
            points("Bar height", $model.glass.tabs.height, 16 ... 60)
            points("Gap below the bar", $model.glass.tabs.spacing, 0 ... 40)
            points("Gap above the bar", $model.glass.tabs.padding, 0 ... 40)
            points("Corner radius", $model.glass.tabs.cornerRadius, 0 ... 24)
            points("Font size", $model.glass.tabs.fontSize, 8 ... 24)
            color("Strip", $model.glass.tabs.barTint)
            color("Unselected tab", $model.glass.tabs.inactiveTint)
            color("Selected tab", $model.glass.tabs.activeTint)
            optionalColor("Label", $model.glass.tabs.textColor)
            optionalColor("Selected label", $model.glass.tabs.activeTextColor)
            optionalColor("Selected outline", $model.glass.tabs.activeBorderColor)
        }
    }

    private var bordersSection: some View {
        Section("Borders") {
            Toggle("Draw borders", isOn: $model.glass.borders.enabled)
            Toggle("Border unfocused windows too", isOn: $model.glass.borders.showInactive)
            Toggle("Reserve gap room for the ring", isOn: $model.glass.borders.expandGaps)
            Toggle("Match each window's corner radius", isOn: $model.glass.borders.detectCornerRadius)
            points("Ring width", $model.glass.borders.width, 0 ... 24)
            points("Solid accent width", $model.glass.borders.strokeWidth, 0 ... 24)
            points("Corner radius", $model.glass.borders.cornerRadius, 0 ... 40)
                .disabled(model.glass.borders.detectCornerRadius)
            points("Outward padding", $model.glass.borders.padding, 0 ... 20)
            color("Focused", $model.glass.borders.activeColor)
            color("Unfocused", $model.glass.borders.inactiveColor)
        }
    }

    private var dropPreviewSection: some View {
        Section("Drag preview") {
            Toggle("Show the drop preview", isOn: $model.glass.dropPreview.enabled)
            points("Corner radius", $model.glass.dropPreview.cornerRadius, 0 ... 24)
            color("Target fill", $model.glass.dropPreview.tint)
            color("Target outline", $model.glass.dropPreview.strokeColor)
            color("Other cells", $model.glass.dropPreview.cellColor)
        }
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let status = model.status {
                Text(status).font(.caption).foregroundStyle(.secondary).lineLimit(2)
            }
            HStack {
                Button("Copy TOML") { model.copySnippet() }
                Button("Revert") { model.revert() }
                Spacer()
                Button("Save to config") { model.save() }
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(16)
    }

    // MARK: - Rows

    @ViewBuilder
    private func points(_ label: String, _ value: Binding<Double>, _ range: ClosedRange<Double>) -> some View {
        HStack {
            Text(label)
            Spacer()
            // Whole points only: the config parser has no float type, so offering fractions here
            // would promise something the file can't hold.
            Text("\(Int(value.wrappedValue.rounded()))")
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .frame(width: 34, alignment: .trailing)
            Slider(value: value, in: range, step: 1).frame(width: 180)
        }
    }

    private func color(_ label: String, _ value: Binding<GlassColor>) -> some View {
        HStack {
            Text(label)
            Spacer()
            Text(GlassConfigWriter.hex(value.wrappedValue))
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
            ColorPicker("", selection: Binding(
                get: { Color(value.wrappedValue.toNSColor) },
                set: { value.wrappedValue = $0.toGlassColor },
            ), supportsOpacity: true)
                .labelsHidden()
        }
    }

    /// A color that means "derive it" when unset, so it needs a way back to unset.
    private func optionalColor(_ label: String, _ value: Binding<GlassColor?>) -> some View {
        HStack {
            Text(label)
            Spacer()
            if value.wrappedValue == nil {
                Text("derived").font(.caption).foregroundStyle(.secondary)
                Button("Set") { value.wrappedValue = GlassColor(red: 1, green: 1, blue: 1, alpha: 0.92) }
                    .controlSize(.small)
            } else {
                Button("Derive") { value.wrappedValue = nil }
                    .controlSize(.small)
                ColorPicker("", selection: Binding(
                    get: { Color((value.wrappedValue ?? GlassColor(red: 1, green: 1, blue: 1, alpha: 1)).toNSColor) },
                    set: { value.wrappedValue = $0.toGlassColor },
                ), supportsOpacity: true)
                    .labelsHidden()
            }
        }
    }

    private func Section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.headline)
            content()
        }
    }
}

extension Color {
    /// SwiftUI's color goes through NSColor to reach sRGB components, which is the space the
    /// config's hex values are in.
    var toGlassColor: GlassColor {
        let ns = NSColor(self).usingColorSpace(.sRGB) ?? .white
        return GlassColor(
            red: Double(ns.redComponent),
            green: Double(ns.greenComponent),
            blue: Double(ns.blueComponent),
            alpha: Double(ns.alphaComponent),
        )
    }
}
