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
    var borders: GlassBordersConfig = GlassBordersConfig()
    var tabs: GlassTabsConfig = GlassTabsConfig()
    var dropPreview: GlassDropPreviewConfig = GlassDropPreviewConfig()
}

struct GlassBordersConfig: ConvenienceMutable {
    var enabled: Bool = false
    /// Stroke thickness in points
    var width: Double = 3
    /// Corner radius of the stroke. macOS windows are ~10pt rounded on Tahoe
    var cornerRadius: Double = 11
    /// Per-app overrides for `cornerRadius`, keyed by app bundle id. Most windows share the system
    /// radius, but apps that draw their own chrome (terminals, Electron apps with custom frames)
    /// can have square or unusual corners that make the standard ring float around them.
    var appCornerRadius: [String: Double] = [:]
    /// Outward offset from the window frame. 0 means the stroke sits flush against the window
    /// edge; raise it to leave a sliver of air between the window and its border
    var padding: Double = 0
    var activeColor: GlassColor = GlassColor(red: 0.55, green: 0.78, blue: 1.0, alpha: 0.95)
    var inactiveColor: GlassColor = GlassColor(red: 1.0, green: 1.0, blue: 1.0, alpha: 0.18)
    /// Draw a border around unfocused windows too
    var showInactive: Bool = true
}

struct GlassTabsConfig: ConvenienceMutable {
    var enabled: Bool = true
    /// Height of the tab bar strip reserved above a `tabbed` container
    var height: Double = 30
    /// Gap above the bar, between the top edge of the tile and the strip
    var padding: Double = 0
    /// Gap between the tab bar and the window content below it
    var spacing: Double = 4
    var cornerRadius: Double = 10
    var fontSize: Double = 12
    /// Show each window's app icon in its tab
    var showIcons: Bool = true
    /// The three fills form a value ramp: the strip is dim, unselected tabs sit a shade darker
    /// against it, and the selected tab is the lightest thing in the bar — lighter than its
    /// neighbors without turning into a solid chip.
    var barTint: GlassColor = GlassColor(red: 0, green: 0, blue: 0, alpha: 0.22)
    var inactiveTint: GlassColor = GlassColor(red: 0, green: 0, blue: 0, alpha: 0.28)
    var activeTint: GlassColor = GlassColor(red: 1, green: 1, blue: 1, alpha: 0.35)
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
