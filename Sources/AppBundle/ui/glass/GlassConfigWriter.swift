import AppKit
import Common

/// Writes the `glass.*` keys back into the user's config without disturbing the rest of it.
///
/// The config is a file people hand-write and comment, so this edits lines rather than
/// re-serialising a parsed document: a key that is already present has its value replaced in
/// place, keeping its comment and position, and only genuinely new keys are appended. Anything
/// that isn't a `glass.*` assignment is copied through untouched.
///
/// TOML dotted keys belong to whatever table precedes them, so `glass.*` lines are only valid
/// before the first `[table]` header. Appended keys go immediately before that header for the same
/// reason.
@MainActor
enum GlassConfigWriter {
    enum WriteError: Error, CustomStringConvertible {
        case unreadable(String)
        case unwritable(String)

        var description: String {
            switch self {
                case .unreadable(let path): "Can't read \(path)"
                case .unwritable(let path): "Can't write \(path)"
            }
        }
    }

    /// The value each `glass.*` key holds in a default config, used to keep untouched settings out
    /// of the file.
    static let defaults: [String: String] =
        Dictionary(uniqueKeysWithValues: lines(for: GlassConfig()).map { ($0.key, $0.value) })

    /// Every `glass.*` key with the value it currently holds, in the order the panel presents them.
    static func lines(for glass: GlassConfig) -> [(key: String, value: String)] {
        var out: [(String, String)] = []
        func put(_ key: String, _ value: String) { out.append((key, value)) }

        put("glass.theme.from-wallpaper", bool(glass.theme.fromWallpaper))
        put("glass.theme.palette", quoted(glass.theme.palette.rawValue))

        put("glass.borders.enabled", bool(glass.borders.enabled))
        put("glass.borders.width", points(glass.borders.width))
        put("glass.borders.stroke-width", points(glass.borders.strokeWidth))
        put("glass.borders.expand-gaps", bool(glass.borders.expandGaps))
        put("glass.borders.detect-corner-radius", bool(glass.borders.detectCornerRadius))
        put("glass.borders.corner-radius", points(glass.borders.cornerRadius))
        put("glass.borders.padding", points(glass.borders.padding))
        put("glass.borders.show-inactive", bool(glass.borders.showInactive))
        put("glass.borders.active-color", quoted(hex(glass.borders.activeColor)))
        put("glass.borders.inactive-color", quoted(hex(glass.borders.inactiveColor)))

        put("glass.tabs.enabled", bool(glass.tabs.enabled))
        put("glass.tabs.style", quoted(glass.tabs.style.rawValue))
        put("glass.tabs.height", points(glass.tabs.height))
        put("glass.tabs.padding", points(glass.tabs.padding))
        put("glass.tabs.spacing", points(glass.tabs.spacing))
        put("glass.tabs.corner-radius", points(glass.tabs.cornerRadius))
        put("glass.tabs.font-size", points(glass.tabs.fontSize))
        put("glass.tabs.fixed-width", bool(glass.tabs.fixedWidth))
        put("glass.tabs.width", points(glass.tabs.width))
        put("glass.tabs.show-icons", bool(glass.tabs.showIcons))
        put("glass.tabs.bar-tint", quoted(hex(glass.tabs.barTint)))
        put("glass.tabs.inactive-tint", quoted(hex(glass.tabs.inactiveTint)))
        put("glass.tabs.active-tint", quoted(hex(glass.tabs.activeTint)))
        // The three "derive it when unset" keys are only written once they hold a value, so that
        // saving from the panel can't silently pin a color the config was happy to leave derived.
        if let c = glass.tabs.textColor { put("glass.tabs.text-color", quoted(hex(c))) }
        if let c = glass.tabs.activeTextColor { put("glass.tabs.active-text-color", quoted(hex(c))) }
        if let c = glass.tabs.activeBorderColor { put("glass.tabs.active-border-color", quoted(hex(c))) }

        put("glass.drop-preview.enabled", bool(glass.dropPreview.enabled))
        put("glass.drop-preview.corner-radius", points(glass.dropPreview.cornerRadius))
        put("glass.drop-preview.tint", quoted(hex(glass.dropPreview.tint)))
        put("glass.drop-preview.stroke-color", quoted(hex(glass.dropPreview.strokeColor)))
        put("glass.drop-preview.cell-color", quoted(hex(glass.dropPreview.cellColor)))

        return out
    }

    /// The `glass.*` block as it would be pasted into a config, for the panel's copy button.
    static func snippet(for glass: GlassConfig) -> String {
        lines(for: glass).map { "\($0.key) = \($0.value)" }.joined(separator: "\n") + "\n"
    }

    /// Rewrite `url` so its `glass.*` keys match `glass`. The previous contents are copied to a
    /// sibling `.bak` first, because this edits a file the user maintains by hand.
    @discardableResult
    static func save(_ glass: GlassConfig, to url: URL) throws -> URL {
        guard let original = try? String(contentsOf: url, encoding: .utf8) else {
            throw WriteError.unreadable(url.path)
        }
        let backup = url.appendingPathExtension("bak")
        try? original.write(to: backup, atomically: true, encoding: .utf8)

        let updated = apply(lines(for: glass), to: original)
        do {
            try updated.write(to: url, atomically: true, encoding: .utf8)
        } catch {
            throw WriteError.unwritable(url.path)
        }
        return backup
    }

    /// Replace in place, append what's missing. Exposed for tests.
    static func apply(_ pairs: [(key: String, value: String)], to source: String) -> String {
        var remaining = pairs.reduce(into: [String: String]()) { $0[$1.key] = $1.value }
        var lines = source.components(separatedBy: "\n")

        for (i, line) in lines.enumerated() {
            guard let key = assignedKey(in: line), let value = remaining[key],
                  let equals = line.firstIndex(of: "=") else { continue }
            // Only the value itself is replaced. Everything the author chose around it survives:
            // the indent, the padding lining values up in a column, and the run of spaces before a
            // trailing comment, which is usually lining the comments up too.
            let head = String(line[...equals])
            let rest = String(line[line.index(after: equals)...])
            let gap = String(rest.prefix(while: { $0 == " " }))
            let afterGap = String(rest.dropFirst(gap.count))
            if let commentStart = commentIndex(in: afterGap) {
                let oldValue = String(afterGap[..<commentStart])
                let padding = String(oldValue.reversed().prefix(while: { $0 == " " }).reversed())
                lines[i] = head + gap + value + padding + String(afterGap[commentStart...])
            } else {
                lines[i] = head + gap + value
            }
            remaining.removeValue(forKey: key)
        }

        // A key the config never mentioned and whose value is still the default has nothing to
        // say, and writing it would grow the file every time the panel is opened.
        remaining = remaining.filter { defaults[$0.key] != $0.value }
        guard !remaining.isEmpty else { return lines.joined(separator: "\n") }

        // Dotted keys after a [table] header would belong to that table, so new ones go above the
        // first header, or at the end when the file has none.
        let additions = pairs.filter { remaining[$0.key] != nil }.map { "\($0.key) = \($0.value)" }
        let insertAt = lines.firstIndex { $0.trimmingCharacters(in: .whitespaces).hasPrefix("[") }
        let block = ["", "# Written by the AeroSpace Glass settings panel"] + additions
        if let insertAt {
            lines.insert(contentsOf: block + [""], at: insertAt)
        } else {
            lines.append(contentsOf: block)
        }
        return lines.joined(separator: "\n")
    }

    // MARK: - Line parsing

    /// The key a line assigns to, if it assigns to a `glass.*` key outside a comment.
    private static func assignedKey(in line: String) -> String? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("glass."), let equals = trimmed.firstIndex(of: "=") else { return nil }
        let key = trimmed[trimmed.startIndex ..< equals].trimmingCharacters(in: .whitespaces)
        return key.allSatisfy { $0.isLetter || $0.isNumber || $0 == "." || $0 == "-" || $0 == "_" } ? key : nil
    }

    /// Where a trailing `# ...` comment starts, ignoring a `#` inside the quoted value.
    private static func commentIndex(in text: String) -> String.Index? {
        var inQuotes = false
        var quote: Character = "'"
        for (offset, char) in text.enumerated() {
            if char == "'" || char == "\"" {
                if !inQuotes { inQuotes = true; quote = char } else if char == quote { inQuotes = false }
            } else if char == "#", !inQuotes {
                return text.index(text.startIndex, offsetBy: offset)
            }
        }
        return nil
    }

    // MARK: - Value formatting

    private static func bool(_ value: Bool) -> String { value ? "true" : "false" }
    private static func quoted(_ value: String) -> String { "'\(value)'" }
    /// The parser takes whole points only, so a value is rounded rather than written as a float.
    private static func points(_ value: Double) -> String { String(Int(value.rounded())) }

    static func hex(_ color: GlassColor) -> String {
        func channel(_ value: Double) -> Int { Int((value * 255).rounded()).coerceIn(0 ... 255) }
        let rgb = String(format: "#%02X%02X%02X", channel(color.red), channel(color.green), channel(color.blue))
        return color.alpha >= 1 ? rgb : rgb + String(format: "%02X", channel(color.alpha))
    }
}

extension Int {
    fileprivate func coerceIn(_ range: ClosedRange<Int>) -> Int { Swift.min(Swift.max(self, range.lowerBound), range.upperBound) }
}
