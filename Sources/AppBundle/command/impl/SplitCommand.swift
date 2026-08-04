import AppKit
import Common

struct SplitCommand: Command {
    let args: SplitCmdArgs
    /*conforms*/ let shouldResetClosedWindowsCache = true

    func run(_ env: CmdEnv, _ io: CmdIo) -> BinaryExitCode {
        guard let target = args.resolveTargetOrReportError(env, io) else { return .fail }
        guard let window = target.windowOrNil else {
            return .fail(io.err(noWindowIsFocused))
        }
        guard let parent = window.parent else { return .fail(io.err(bugPrompt())) }
        switch parent.cases {
            case .floatingWindowsContainer:
                // Nothing to do for floating and macOS native fullscreen windows
                return .fail(io.err("Can't split floating windows"))
            case .tilingContainer(let parent):
                let orientation: Orientation = switch args.arg.val {
                    case .vertical: .v
                    case .horizontal: .h
                    case .opposite: parent.orientation.opposite
                }
                // Splitting eagerly is pointless while the flatten normalization is on: a container
                // with a single child is immediately flattened away again. Record i3's intent
                // instead, and honor it when the next window opens beside this one.
                if config.enableNormalizationFlattenContainers {
                    // Splitting from inside a tab divides the whole tab group rather than nesting a
                    // split within the focused tab, which would leave the other tabs at the old
                    // size while only the visible one shrank. i3 reaches the group with
                    // 'focus parent' first; AeroSpace has no equivalent, so mark the group here.
                    let target: TreeNode = parent.layout == .tabbed ? parent : window
                    target.pendingSplitOrientation = orientation
                    return .succ
                }
                if parent.children.count == 1 {
                    parent.changeOrientation(orientation)
                    parent.hasUserDefinedOrientation = true
                } else {
                    let data = window.unbindFromParent()
                    let newParent = TilingContainer(
                        parent: parent,
                        adaptiveWeight: data.adaptiveWeight,
                        orientation,
                        .tiles,
                        index: data.index,
                    )
                    newParent.hasUserDefinedOrientation = true
                    window.bind(to: newParent, adaptiveWeight: WEIGHT_AUTO, index: 0)
                }
                return .succ
            case .macosMinimizedWindowsContainer, .macosFullscreenWindowsContainer, .macosHiddenAppsWindowsContainer:
                return .fail(io.err("Can't split macos fullscreen, minimized windows and windows of hidden apps. This behavior may change in the future"))
            case .macosPopupWindowsContainer, .workspace:
                return .fail(io.err(bugPrompt())) // Impossible
        }
    }
}
