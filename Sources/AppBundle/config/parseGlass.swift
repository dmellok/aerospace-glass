import Common

private let glassParser: [String: any ParserProtocol<GlassConfig>] = [
    "borders": Parser(\.borders, parseGlassBorders),
    "tabs": Parser(\.tabs, parseGlassTabs),
]

private let glassBordersParser: [String: any ParserProtocol<GlassBordersConfig>] = [
    "enabled": Parser(\.enabled, parseBool),
    "width": Parser(\.width, parsePoints),
    "corner-radius": Parser(\.cornerRadius, parsePoints),
    "padding": Parser(\.padding, parsePoints),
    "active-color": Parser(\.activeColor, parseGlassColor),
    "inactive-color": Parser(\.inactiveColor, parseGlassColor),
    "show-inactive": Parser(\.showInactive, parseBool),
]

private let glassTabsParser: [String: any ParserProtocol<GlassTabsConfig>] = [
    "enabled": Parser(\.enabled, parseBool),
    "height": Parser(\.height, parsePoints),
    "spacing": Parser(\.spacing, parsePoints),
    "corner-radius": Parser(\.cornerRadius, parsePoints),
    "font-size": Parser(\.fontSize, parsePoints),
    "show-icons": Parser(\.showIcons, parseBool),
    "active-tint": Parser(\.activeTint, parseGlassColor),
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
