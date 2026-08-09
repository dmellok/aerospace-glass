import AppKit
import Common
import HotKey
import OrderedCollections

func getDefaultConfigUrlFromProject() -> URL {
    var url = URL(filePath: #filePath)
    check(FileManager.default.fileExists(atPath: url.path))
    while !FileManager.default.fileExists(atPath: url.appending(component: ".git").path) {
        url.deleteLastPathComponent()
    }
    let projectRoot: URL = url
    return projectRoot.appending(component: "docs/config-examples/default-config.toml")
}

var defaultConfigUrl: URL {
    if isUnitTest {
        return getDefaultConfigUrlFromProject()
    } else {
        return Bundle.main.url(forResource: "default-config", withExtension: "toml")
            // Useful for debug builds that are not app bundles
            ?? getDefaultConfigUrlFromProject()
    }
}
@MainActor let defaultConfig: Config = {
    let parsedConfig = parseConfig(Result { try String(contentsOf: defaultConfigUrl, encoding: .utf8) }.getOrDie())
    if !parsedConfig.errors.isEmpty {
        die("Can't parse default config: \(parsedConfig.errors)")
    }
    return parsedConfig.config
}()
@MainActor var config: Config = defaultConfig // todo move to Ctx?
@MainActor var configUrl: URL = defaultConfigUrl

struct Config: ConvenienceMutable {
    var configVersion: ConfigVersion = ._1
    var _afterLoginCommand: [any Command] = []
    var afterStartupCommand: Shell<any Command> = .empty
    var _indentForNestedContainersWithTheSameOrientation: Void = ()
    var enableNormalizationFlattenContainers: Bool = true
    var _nonEmptyWorkspacesRootContainersLayoutOnStartup: Void = ()
    var defaultRootContainerLayout: Layout = .tiles
    var defaultRootContainerOrientation: DefaultContainerOrientation = .auto
    var startAtLogin: Bool = false
    var autoReloadConfig: Bool = false
    var automaticallyUnhideMacosHiddenApps: Bool = false
    var accordionPadding: Int = 30
    var enableNormalizationOppositeOrientationForNestedContainers: Bool = true
    var persistentWorkspaces: OrderedSet<String> = []
    var execOnWorkspaceChange: [String] = [] // todo deprecate
    var keyMapping = KeyMapping()
    var execConfig: ExecConfig = ExecConfig()
    var focusFollowsMouse: FocusFollowsMouse = FocusFollowsMouse()

    var onFocusChanged: Shell<any Command> = .empty
    // var onFocusedWorkspaceChanged: [any Command] = []
    var onFocusedMonitorChanged: Shell<any Command> = .empty

    var gaps: Gaps = .zero
    var workspaceToMonitorForceAssignment: [String: [MonitorDescription]] = [:]
    var modes: [String: Mode] = [:]
    var onWindowDetected: [WindowDetectedCallback] = []
    var onModeChanged: Shell<any Command> = .empty

    /// Keep floating windows above the tiled layer, i3-style. Approximated with the Accessibility
    /// raise action, since macOS can't pin another process's window at a higher level.
    var floatingWindowsOnTop: Bool = false

    var glass: GlassConfig = GlassConfig()
}

struct FocusFollowsMouse: ConvenienceMutable {
    var enabled: Bool = false
}

/// Appearance of the native macOS glass decorations that this fork draws on top of managed windows.
struct GlassConfig: ConvenienceMutable {
    var theme: GlassThemeConfig = GlassThemeConfig()
    var borders: GlassBordersConfig = GlassBordersConfig()
    var tabs: GlassTabsConfig = GlassTabsConfig()
    var dropPreview: GlassDropPreviewConfig = GlassDropPreviewConfig()
}

/// How many of the wallpaper's colors the palette is built from.
enum GlassThemePalette: String {
    /// One sampled dark tone and one sampled accent; the second surface and the unfocused ring
    /// are arithmetic on the first. Safe on any picture, but the bar is three brightnesses of a
    /// single hue.
    case mono
    /// Each role gets a tone the picture actually contains, chosen to be distinct from the others,
    /// so the decorations carry the wallpaper's own color relationships. Falls back to the derived
    /// value per role when the picture has no distinct tone to offer it.
    case multi
}

struct GlassThemeConfig: ConvenienceMutable {
    /// Sample the decoration colors from the desktop picture instead of taking them from the
    /// config. It fills the tints, the accent and the label colors; the sizes, and every key the
    /// palette has no opinion about, are still yours.
    ///
    /// While this is on, the palette owns the tints, the border colors and the drop preview's
    /// accent — setting those keys has no effect. The keys that default to "derive it"
    /// (`tabs.text-color`, `tabs.active-text-color`, `tabs.active-border-color`) still win when
    /// set, so labels can be pinned without giving up the sampled surfaces.
    ///
    /// When the wallpaper can't be sampled — an aerial video, an unreadable file, a picture with
    /// no usable tones — every configured color is used unchanged.
    var fromWallpaper: Bool = false
    /// `mono` derives the surfaces from one sampled tone; `multi` samples a distinct tone per role
    /// — the tab bar strip, unselected tabs, the accent, and the unfocused window ring.
    var palette: GlassThemePalette = .mono
}

struct GlassBordersConfig: ConvenienceMutable {
    var enabled: Bool = false
    /// Total ring thickness in points. Most of it is tinted glass; see ``strokeWidth``
    var width: Double = 3
    /// Points of solid accent along the ring's outer edge, out of ``width``. The rest stays glass,
    /// so raising this trades refraction for a harder edge — at `width` the ring is a flat stroke.
    /// Clamped to `width`.
    var strokeWidth: Double = 1
    /// Grow the layout gaps so neighbouring windows' rings don't meet. Inner gaps take twice the
    /// ring's outward reach (both sides have one), outer gaps take it once. Only has an effect
    /// while borders are drawn.
    var expandGaps: Bool = true
    /// Corner radius of the stroke, used when the window's own radius can't be determined.
    /// macOS windows are ~10pt rounded on Tahoe
    var cornerRadius: Double = 11
    /// Ask the window server for each window's actual corner radius instead of using
    /// `cornerRadius` for all of them. Windows genuinely differ — on macOS 26 a Safari window is
    /// 26pt where a VS Code window is 16pt — so one configured value is wrong for some of them.
    ///
    /// This reads a private SkyLight symbol, resolved at runtime rather than linked. Where it
    /// isn't available the configured radius is used, so turning this off costs nothing but the
    /// accuracy. See ``WindowCornerRadius``.
    var detectCornerRadius: Bool = true
    /// Per-app overrides, keyed by app bundle id. These win over both the detected radius and
    /// `cornerRadius`, so an app whose reported radius doesn't suit its chrome can be corrected.
    var appCornerRadius: [String: Double] = [:]
    /// Outward offset from the window frame. 0 means the stroke sits flush against the window
    /// edge; raise it to leave a sliver of air between the window and its border
    var padding: Double = 0
    var activeColor: GlassColor = GlassColor(red: 0.55, green: 0.78, blue: 1.0, alpha: 0.95)
    var inactiveColor: GlassColor = GlassColor(red: 1.0, green: 1.0, blue: 1.0, alpha: 0.18)
    /// Draw a border around unfocused windows too
    var showInactive: Bool = true
}

/// How the tab bar is painted.
enum GlassTabsStyle: String {
    /// Liquid Glass on macOS 26, blur materials below it. The tints are composited over whatever
    /// shows through, so they read as washes rather than as the colors you typed.
    case glass
    /// Flat fills, nothing showing through. The tints are drawn exactly as configured, so give
    /// them full alpha (`'#1E1E2E'`) unless you want the app content behind to bleed in.
    case flat
}

struct GlassTabsConfig: ConvenienceMutable {
    var enabled: Bool = true
    /// `glass` blurs the backdrop; `flat` paints the configured colors literally
    var style: GlassTabsStyle = .glass
    /// Height of the tab bar strip reserved above a `tabbed` container
    var height: Double = 30
    /// Gap above the bar, between the top edge of the tile and the strip
    var padding: Double = 0
    /// Gap between the tab bar and the window content below it
    var spacing: Double = 4
    var cornerRadius: Double = 10
    var fontSize: Double = 12
    /// Give every tab the same fixed ``width`` instead of dividing the bar between them. Tabs still
    /// shrink once they stop fitting, the way a browser narrows its tabs rather than overflowing.
    var fixedWidth: Bool = false
    /// Width of one tab in points while ``fixedWidth`` is on. Ignored otherwise.
    var width: Double = 180
    /// Show each window's app icon in its tab
    var showIcons: Bool = true
    /// The three fills form a value ramp: the strip is dim, unselected tabs sit a shade darker
    /// against it, and the selected tab is the lightest thing in the bar — lighter than its
    /// neighbors without turning into a solid chip.
    var barTint: GlassColor = GlassColor(red: 0, green: 0, blue: 0, alpha: 0.22)
    var inactiveTint: GlassColor = GlassColor(red: 0, green: 0, blue: 0, alpha: 0.28)
    var activeTint: GlassColor = GlassColor(red: 1, green: 1, blue: 1, alpha: 0.35)
    /// Label color of the selected tab. Unset picks black or white from the fill's luminance, which
    /// is right for most themes — the decorations float over arbitrary app content, so the system
    /// appearance says nothing about what a label will sit on. Set it to take that over.
    var activeTextColor: GlassColor? = nil
    /// Label color of unselected tabs. Unset derives it from ``inactiveTint`` the same way.
    var textColor: GlassColor? = nil
    /// Hairline around the selected tab, which is what marks the selection on a backdrop where the
    /// fills alone don't carry. Unset uses a white hairline.
    var activeBorderColor: GlassColor? = nil
}

/// The overlay shown while a window or tab is dragged: the workspace's splits as faint outlines,
/// and the slot the drop would land in as a blurred glass fill.
struct GlassDropPreviewConfig: ConvenienceMutable {
    var enabled: Bool = true
    var cornerRadius: Double = 10
    /// Fill of the active drop slot, composited over the glass blur. Kept faint so the slot reads
    /// as glass — the blur does the work, the tint only names the accent
    var tint: GlassColor = GlassColor(red: 0.55, green: 0.78, blue: 1.0, alpha: 0.13)
    /// Outline of the active drop slot, and the tab insertion caret
    var strokeColor: GlassColor = GlassColor(red: 0.55, green: 0.78, blue: 1.0, alpha: 0.9)
    /// Outline of the inactive cells sketching the rest of the layout
    var cellColor: GlassColor = GlassColor(red: 1, green: 1, blue: 1, alpha: 0.25)
}

struct GlassColor: Equatable, Sendable {
    var red: Double
    var green: Double
    var blue: Double
    var alpha: Double
}

enum ConfigVersion: Int, Comparable, CaseIterable, Sendable, CustomStringConvertible {
    case _1 = 1
    case _2 = 2

    static let max = allCases.max().orDie()
    static let min = allCases.min().orDie()
    static func < (lhs: ConfigVersion, rhs: ConfigVersion) -> Bool { lhs.rawValue < rhs.rawValue }

    var description: String { rawValue.description }
}

enum DefaultContainerOrientation: String {
    case horizontal, vertical, auto
}
