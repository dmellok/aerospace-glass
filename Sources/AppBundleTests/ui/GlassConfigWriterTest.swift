@testable import AppBundle
import Common
import XCTest

@MainActor
final class GlassConfigWriterTest: XCTestCase {
    /// The file belongs to the user, so everything that isn't a `glass.*` assignment has to survive
    /// a save untouched: comments, blank lines, ordering, and the rest of the config.
    func testKeepsEverythingItDoesNotOwn() {
        let source = """
            # my config
            start-at-login = true

            # Borders, tuned by hand
            glass.borders.enabled = false
            glass.borders.width = 3

            [mode.main.binding]
            alt-h = 'focus left'
            """
        let result = GlassConfigWriter.apply(
            [("glass.borders.enabled", "true"), ("glass.borders.width", "6")],
            to: source,
        )
        XCTAssertTrue(result.contains("# my config"))
        XCTAssertTrue(result.contains("start-at-login = true"))
        XCTAssertTrue(result.contains("# Borders, tuned by hand"))
        XCTAssertTrue(result.contains("glass.borders.enabled = true"))
        XCTAssertTrue(result.contains("glass.borders.width = 6"))
        XCTAssertTrue(result.contains("alt-h = 'focus left'"))
        XCTAssertFalse(result.contains("glass.borders.enabled = false"))
    }

    /// A value is replaced where it already sits, so the key keeps its position and its comment.
    func testReplacesInPlaceAndKeepsTrailingComments() {
        let source = "glass.tabs.height = 30  # tall enough for the title\nglass.tabs.font-size = 12"
        let result = GlassConfigWriter.apply([("glass.tabs.height", "40")], to: source)
        XCTAssertEqual(
            result,
            "glass.tabs.height = 40  # tall enough for the title\nglass.tabs.font-size = 12",
        )
    }

    /// A `#` inside a quoted color isn't a comment.
    func testDoesNotMistakeAHexColorForAComment() {
        let source = "glass.borders.active-color = '#8CC7FF'"
        let result = GlassConfigWriter.apply([("glass.borders.active-color", "'#FF0000'")], to: source)
        XCTAssertEqual(result, "glass.borders.active-color = '#FF0000'")
    }

    /// Dotted keys belong to whatever table precedes them, so a new one written after a `[table]`
    /// header would land inside that table and fail to parse as a glass key.
    func testAppendsNewKeysBeforeTheFirstTableHeader() {
        let source = "start-at-login = true\n\n[mode.main.binding]\nalt-h = 'focus left'"
        // A non-default value, since defaults are deliberately not appended
        let result = GlassConfigWriter.apply([("glass.tabs.fixed-width", "true")], to: source)
        let added = result.range(of: "glass.tabs.fixed-width = true")
        let header = result.range(of: "[mode.main.binding]")
        XCTAssertNotNil(added)
        XCTAssertNotNil(header)
        XCTAssertTrue(added!.lowerBound < header!.lowerBound)
    }

    /// What the panel writes has to parse back into what the panel held, or Save quietly loses
    /// settings.
    func testRoundTripsThroughTheParser() {
        var glass = GlassConfig()
        glass.theme.fromWallpaper = true
        glass.theme.palette = .multi
        glass.borders.enabled = true
        glass.borders.width = 6
        glass.borders.strokeWidth = 2
        glass.tabs.style = .flat
        glass.tabs.fixedWidth = true
        glass.tabs.width = 220
        glass.tabs.activeTextColor = GlassColor(red: 1, green: 0, blue: 0.5, alpha: 0.8)

        let parsed = parseConfig(GlassConfigWriter.snippet(for: glass))
        XCTAssertEqual(parsed.errors, [])
        XCTAssertEqual(parsed.config.glass.theme.fromWallpaper, true)
        XCTAssertEqual(parsed.config.glass.theme.palette, .multi)
        XCTAssertEqual(parsed.config.glass.borders.width, 6)
        XCTAssertEqual(parsed.config.glass.borders.strokeWidth, 2)
        XCTAssertEqual(parsed.config.glass.tabs.style, .flat)
        XCTAssertEqual(parsed.config.glass.tabs.fixedWidth, true)
        XCTAssertEqual(parsed.config.glass.tabs.width, 220)
        XCTAssertEqual(parsed.config.glass.tabs.activeTextColor?.red, 1)
        XCTAssertEqual(parsed.config.glass.tabs.activeTextColor?.alpha ?? 0, 0.8, accuracy: 0.01)
    }

    /// People line their values up in a column. Replacing a value must not reflow the file.
    func testKeepsTheAuthorsAlignment() {
        let source = "glass.tabs.bar-tint =      '#1E1E2E'\nglass.tabs.active-tint =   '#C084FC'"
        let result = GlassConfigWriter.apply([("glass.tabs.bar-tint", "'#000000'")], to: source)
        XCTAssertEqual(
            result,
            "glass.tabs.bar-tint =      '#000000'\nglass.tabs.active-tint =   '#C084FC'",
        )
    }

    /// The spaces before a trailing comment usually line the comments up too, so they are the
    /// author's formatting just as much as the value padding is.
    func testKeepsTheGapBeforeATrailingComment() {
        let source = "glass.borders.show-inactive = false   # only the focused window gets a ring"
        let result = GlassConfigWriter.apply([("glass.borders.show-inactive", "true")], to: source)
        XCTAssertEqual(result, "glass.borders.show-inactive = true   # only the focused window gets a ring")
    }

    /// Saving shouldn't paste in every key the panel knows about. A setting the config never
    /// mentioned, still sitting at its default, has nothing to say.
    func testDoesNotAppendUntouchedDefaults() {
        let source = "glass.borders.enabled = true"
        let result = GlassConfigWriter.apply(GlassConfigWriter.lines(for: {
            var glass = GlassConfig()
            glass.borders.enabled = true
            return glass
        }()), to: source)
        XCTAssertEqual(result, "glass.borders.enabled = true")
    }

    /// A non-default value the config never mentioned does need writing.
    func testAppendsNonDefaultValues() {
        var glass = GlassConfig()
        glass.tabs.fixedWidth = true
        let result = GlassConfigWriter.apply(GlassConfigWriter.lines(for: glass), to: "start-at-login = true")
        XCTAssertTrue(result.contains("glass.tabs.fixed-width = true"))
        XCTAssertFalse(result.contains("glass.tabs.show-icons"))
    }

    /// The three "derive it when unset" keys must stay absent, or saving would pin a color the
    /// config was content to leave derived.
    func testUnsetDerivedColorsAreNotWritten() {
        let snippet = GlassConfigWriter.snippet(for: GlassConfig())
        XCTAssertFalse(snippet.contains("text-color"))
        XCTAssertFalse(snippet.contains("active-border-color"))
    }
}
