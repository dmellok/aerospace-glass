import AppKit
import Common

struct ResizeCommand: Command {
    let args: ResizeCmdArgs
    /*conforms*/ let shouldResetClosedWindowsCache = true

    func run(_ env: CmdEnv, _ io: CmdIo) async -> BinaryExitCode {
        guard let target = args.resolveTargetOrReportError(env, io) else { return .fail }

        if let window = target.windowOrNil, window.parent is FloatingWindowsContainer {
            return await resizeFloating(window, args, io)
        }

        let candidates = target.windowOrNil?.parentsWithSelf
            .filter { ($0.parent as? TilingContainer)?.layout == .tiles }
            ?? []

        let orientation: Orientation?
        let parent: TilingContainer?
        let node: TreeNode?
        switch args.dimension.val {
            case .width:
                orientation = .h
                node = candidates.first(where: { ($0.parent as? TilingContainer)?.orientation == orientation })
                parent = node?.parent as? TilingContainer
            case .height:
                orientation = .v
                node = candidates.first(where: { ($0.parent as? TilingContainer)?.orientation == orientation })
                parent = node?.parent as? TilingContainer
            case .smart:
                node = candidates.first
                parent = node?.parent as? TilingContainer
                orientation = parent?.orientation
            case .smartOpposite:
                orientation = (candidates.first?.parent as? TilingContainer)?.orientation.opposite
                node = candidates.first(where: { ($0.parent as? TilingContainer)?.orientation == orientation })
                parent = node?.parent as? TilingContainer
        }
        guard let parent else {
            return .fail(io.err("resize command doesn't support floating windows yet https://github.com/nikitabobko/AeroSpace/issues/9"))
        }
        guard let orientation else { return .fail }
        guard let node else { return .fail }
        let diff: CGFloat = switch args.units.val {
            case .set(let unit): CGFloat(unit) - node.getWeight(orientation)
            case .add(let unit): CGFloat(unit)
            case .subtract(let unit): -CGFloat(unit)
        }

        guard let childDiff = diff.div(parent.children.count - 1) else { return .fail }
        parent.children.lazy
            .filter { $0 != node }
            .forEach { $0.setWeight(parent.orientation, $0.getWeight(parent.orientation) - childDiff) }

        node.setWeight(orientation, node.getWeight(orientation) + diff)
        return .succ
    }
}

/// Floating windows have no weights to shuffle; resize changes the window frame itself, the way i3
/// resizes its floating windows. The top-left corner stays put, `smart` resizes both dimensions.
@MainActor private func resizeFloating(_ window: Window, _ args: ResizeCmdArgs, _ io: CmdIo) async -> BinaryExitCode {
    guard let rect = try? await window.getAxRect(.cancellable) else {
        return .fail(io.err("Can't read the window frame"))
    }
    let (resizeWidth, resizeHeight): (Bool, Bool) = switch args.dimension.val {
        case .width: (true, false)
        case .height: (false, true)
        case .smart, .smartOpposite: (true, true)
    }
    func apply(_ current: CGFloat) -> CGFloat {
        let new: CGFloat = switch args.units.val {
            case .set(let unit): CGFloat(unit)
            case .add(let unit): current + CGFloat(unit)
            case .subtract(let unit): current - CGFloat(unit)
        }
        // Don't let a window resize itself away entirely; apps clamp harder minimums themselves
        return max(new, 50)
    }
    window.setAxFrame(nil, CGSize(
        width: resizeWidth ? apply(rect.width) : rect.width,
        height: resizeHeight ? apply(rect.height) : rect.height,
    ))
    return .succ
}
