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
                // The split container is created immediately, the way i3 does it, so windows can be
                // moved into it straight away and new windows open inside it. It survives the
                // flatten normalization because ``TilingContainer/isUserDefinedSplit`` marks it as
                // deliberate — otherwise a container holding the single split window would be
                // dissolved again before anything could be moved in.
                //
                // Splitting from inside a tab divides the whole tab group rather than nesting a
                // split within the focused tab, which would leave the other tabs at the old size
                // while only the visible one shrank. i3 reaches the group with 'focus parent'
                // first; AeroSpace has no equivalent, so the group is split directly.
                let node: TreeNode = parent.layout == .tabbed ? parent : window
                guard let grandParent = node.parent as? TilingContainer else {
                    // The tab group is the workspace root: retarget its own orientation instead
                    parent.changeOrientation(orientation)
                    parent.isUserDefinedSplit = true
                    return .succ
                }
                if grandParent.children.count == 1 && node === window {
                    grandParent.changeOrientation(orientation)
                    grandParent.isUserDefinedSplit = true
                    return .succ
                }
                let data = node.unbindFromParent()
                let newParent = TilingContainer(
                    parent: grandParent,
                    adaptiveWeight: data.adaptiveWeight,
                    orientation,
                    .tiles,
                    index: data.index,
                )
                newParent.isUserDefinedSplit = true
                node.bind(to: newParent, adaptiveWeight: WEIGHT_AUTO, index: 0)
                return .succ
            case .macosMinimizedWindowsContainer, .macosFullscreenWindowsContainer, .macosHiddenAppsWindowsContainer:
                return .fail(io.err("Can't split macos fullscreen, minimized windows and windows of hidden apps. This behavior may change in the future"))
            case .macosPopupWindowsContainer, .workspace:
                return .fail(io.err(bugPrompt())) // Impossible
        }
    }
}
