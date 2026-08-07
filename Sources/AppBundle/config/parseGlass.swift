import Common

private let glassParser: [String: any ParserProtocol<GlassConfig>] = [
    "borders": Parser(\.borders, parseGlassBorders),
    "tabs": Parser(\.tabs, parseGlassTabs),
    "drop-preview": Parser(\.dropPreview, parseGlassDropPreview),
]

private let glassBordersParser: [String: any ParserProtocol<GlassBordersConfig>] = [
    "enabled": Parser(\.enabled, parseBool),
    "width": Parser(\.width, parsePoints),
    "corner-radius": Parser(\.cornerRadius, parsePoints),
    "detect-corner-radius": Parser(\.detectCornerRadius, parseBool),
    "app-corner-radius": Parser(\.appCornerRadius, parseAppCornerRadius),
    "padding": Parser(\.padding, parsePoints),
    "active-color": Parser(\.activeColor, parseGlassColor),
    "inactive-color": Parser(\.inactiveColor, parseGlassColor),
    "show-inactive": Parser(\.showInactive, parseBool),
]

private let glassTabsParser: [String: any ParserProtocol<GlassTabsConfig>] = [
    "enabled": Parser(\.enabled, parseBool),
    "height": Parser(\.height, parsePoints),
    "padding": Parser(\.padding, parsePoints),
    "spacing": Parser(\.spacing, parsePoints),
    "corner-radius": Parser(\.cornerRadius, parsePoints),
    "font-size": Parser(\.fontSize, parsePoints),
    "show-icons": Parser(\.showIcons, parseBool),
    "bar-tint": Parser(\.barTint, parseGlassColor),
    "inactive-tint": Parser(\.inactiveTint, parseGlassColor),
    "active-tint": Parser(\.activeTint, parseGlassColor),
]

private let glassDropPreviewParser: [String: any ParserProtocol<GlassDropPreviewConfig>] = [
    "enabled": Parser(\.enabled, parseBool),
    "corner-radius": Parser(\.cornerRadius, parsePoints),
    "tint": Parser(\.tint, parseGlassColor),
    "stroke-color": Parser(\.strokeColor, parseGlassColor),
    "cell-color": Parser(\.cellColor, parseGlassColor),
]

func parseGlass(_ raw: OrderedJson, _ backtrace: ConfigBacktrace, _ c: inout ConfigParserContext) -> GlassConfig {
    parseTable(raw, GlassConfig(), glassParser, backtrace, &c)
}

private func parseGlassBorders(_ raw: OrderedJson, _ backtrace: ConfigBacktrace, _ c: inout ConfigParserContext) -> GlassBordersConfig {
    parseTable(raw, GlassBordersConfig(), glassBordersParser, backtrace, &c)
}

private func parseGlassTabs(_ raw: OrderedJson, _ backtrace: ConfigBacktrace, _ c: inout ConfigParserContext) -> GlassTabsConfig {
    parseTable(raw, GlassTabsConfig(), glassTabsParser, backtrace, &c)
}

private func parseGlassDropPreview(_ raw: OrderedJson, _ backtrace: ConfigBacktrace, _ c: inout ConfigParserContext) -> GlassDropPreviewConfig {
    parseTable(raw, GlassDropPreviewConfig(), glassDropPreviewParser, backtrace, &c)
}

/// A table of `'app.bundle.id' = radius` pairs overriding `corner-radius` for that app's windows.
private func parseAppCornerRadius(_ raw: OrderedJson, _ backtrace: ConfigBacktrace, _ c: inout ConfigParserContext) -> [String: Double] {
    guard let rawTable = raw.asDictOrNil else {
        c.errors += [expectedActualTypeDiagnostic(expected: .table, actual: raw.tomlType, backtrace)]
        return [:]
    }
    var result: [String: Double] = [:]
    for (appBundleId, rawRadius) in rawTable {
        if let radius = parsePoints(rawRadius, backtrace + .key(appBundleId)).getOrNil(appendErrorTo: &c.errors) {
            result[appBundleId] = radius
        }
    }
    return result
}

/// TOML floats aren't representable in ``OrderedJson``, so sizes are configured as whole points.
private func parsePoints(_ raw: OrderedJson, _ backtrace: ConfigBacktrace) -> ResOrConfigParseDiagnostic<Double> {
    parseInt(raw, backtrace).flatMap {
        $0 >= 0
            ? .success(Double($0))
            : .failure(.init(backtrace, "Must not be negative"))
    }
}

/// Accepts `#RRGGBB`, `#RRGGBBAA` and JankyBorders-style `0xAARRGGBB`, so a color can be copied
/// straight out of an existing `borders` setup.
private func parseGlassColor(_ raw: OrderedJson, _ backtrace: ConfigBacktrace) -> ResOrConfigParseDiagnostic<GlassColor> {
    let malformed = ConfigParseDiagnostic(
        backtrace,
        "Malformed color. Expected '#RRGGBB', '#RRGGBBAA' or '0xAARRGGBB'",
    )
    return parseString(raw, backtrace).flatMap { str in
        let body = str.hasPrefix("#")
            ? String(str.dropFirst())
            : str.hasPrefix("0x") || str.hasPrefix("0X") ? String(str.dropFirst(2)) : str
        guard let value = UInt32(body, radix: 16) else { return .failure(malformed) }
        func channel(_ shift: UInt32) -> Double { Double((value >> shift) & 0xFF) / 255 }
        switch body.count {
            case 6: // RRGGBB
                return .success(GlassColor(red: channel(16), green: channel(8), blue: channel(0), alpha: 1))
            case 8 where str.hasPrefix("#"): // RRGGBBAA
                return .success(GlassColor(red: channel(24), green: channel(16), blue: channel(8), alpha: channel(0)))
            case 8: // AARRGGBB
                return .success(GlassColor(red: channel(16), green: channel(8), blue: channel(0), alpha: channel(24)))
            default:
                return .failure(malformed)
        }
    }
}
