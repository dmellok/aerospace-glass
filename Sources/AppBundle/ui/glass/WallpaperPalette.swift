import AppKit

/// A theme sampled from the desktop picture, so the decorations belong to the wallpaper instead of
/// being a palette you have to keep in sync with it by hand.
///
/// Five roles are picked, not five arbitrary colors: two surfaces to stack the tab bar on, an
/// accent for the things that mark focus, and a label color for each surface that is guaranteed
/// legible against it. Anything the wallpaper can't supply — an aerial video, a picture that is one
/// flat colour, an unreadable file — leaves the configured colors in place rather than guessing.
struct WallpaperPalette {
    /// The tab bar strip: the wallpaper's dominant dark tone, opaque.
    var surface: GlassColor
    /// Unselected tabs, one step up from ``surface`` so the bar reads as a value ramp.
    var elevated: GlassColor
    /// Focus: the selected tab, the border ring, the drop preview's outline.
    var accent: GlassColor
    /// Labels on ``surface`` and ``elevated``.
    var onSurface: GlassColor
    /// Labels on ``accent``, which is usually the lightest thing in the bar.
    var onAccent: GlassColor
}

@MainActor
enum WallpaperTheme {
    private typealias RGB = (r: Double, g: Double, b: Double)

    private static var cache: (key: String, palette: WallpaperPalette?)?

    /// The palette for the current desktop picture, or nil when it can't be sampled.
    ///
    /// Recomputed only when the wallpaper file changes. macOS posts no notification for that, so
    /// the URL and its modification date form the cache key and are rechecked on each refresh —
    /// two `stat`s, against decoding an image every layout pass.
    static func palette() -> WallpaperPalette? {
        guard let screen = NSScreen.main,
              let url = NSWorkspace.shared.desktopImageURL(for: screen)
        else { return nil }
        let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
        let key = "\(url.path)|\(modified?.timeIntervalSince1970 ?? 0)"
        if let cache, cache.key == key { return cache.palette }
        let palette = sample(url)
        cache = (key, palette)
        return palette
    }

    static func invalidate() { cache = nil }

    // MARK: - Sampling

    private static func sample(_ url: URL) -> WallpaperPalette? {
        guard let pixels = thumbnailPixels(url, side: 96) else { return nil }

        // Bucket into a coarse cube. Wallpapers are photographs: exact colors each occur once, so
        // counting them individually says nothing about which tones the picture is actually made of.
        var histogram: [Int: (count: Int, r: Double, g: Double, b: Double)] = [:]
        for pixel in pixels {
            let key = (Int(pixel.r * 7.99) << 6) | (Int(pixel.g * 7.99) << 3) | Int(pixel.b * 7.99)
            let bucket = histogram[key] ?? (0, 0, 0, 0)
            histogram[key] = (bucket.count + 1, bucket.r + pixel.r, bucket.g + pixel.g, bucket.b + pixel.b)
        }
        let buckets = histogram.values
            .map { (count: $0.count, color: (r: $0.r / Double($0.count), g: $0.g / Double($0.count), b: $0.b / Double($0.count))) }
            .sorted { $0.count > $1.count }
        guard !buckets.isEmpty else { return nil }

        // The strip wants a dark tone that is actually in the picture. Prefer the most common dark
        // bucket; if the wallpaper has no dark region at all, darken its dominant tone instead so
        // the bar still recedes rather than glowing.
        let darkest = buckets.first { luminance($0.color) < 0.22 }
            ?? buckets.first { luminance($0.color) < 0.4 }
        let surfaceRGB = darkest?.color ?? scaled(buckets[0].color, 0.18)

        // The accent is the most colorful thing the picture offers in quantity: saturation earns
        // its place, but a single vivid pixel shouldn't beat a tone the wallpaper is built from.
        let total = Double(pixels.count)
        let accentRGB = buckets
            .filter { luminance($0.color) > 0.18 && luminance($0.color) < 0.92 }
            .max { a, b in accentScore(a, total) < accentScore(b, total) }?
            .color

        // A greyscale wallpaper has no accent to find. A light neutral still marks focus, and is
        // honest about the picture rather than inventing a hue that isn't there.
        let accent = accentRGB.map { saturate(lighten($0, to: 0.62), by: 1.25) } ?? (r: 0.86, g: 0.87, b: 0.92)

        return WallpaperPalette(
            surface: color(surfaceRGB, alpha: 1),
            elevated: color(lighten(surfaceRGB, to: max(luminance(surfaceRGB) + 0.07, 0.12)), alpha: 1),
            accent: color(accent, alpha: 1),
            onSurface: color(surfaceRGB, alpha: 1).legibleGlassColor,
            onAccent: color(accent, alpha: 1).legibleGlassColor,
        )
    }

    /// Decoded small: the palette only needs the picture's proportions, and a 6K desktop image
    /// decoded in full on the layout path would be absurd.
    private static func thumbnailPixels(_ url: URL, side: Int) -> [RGB]? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                  kCGImageSourceCreateThumbnailFromImageAlways: true,
                  kCGImageSourceThumbnailMaxPixelSize: side,
              ] as CFDictionary)
        else { return nil }

        let width = image.width, height = image.height
        guard width > 0, height > 0 else { return nil }
        var raw = [UInt8](repeating: 0, count: width * height * 4)
        guard let context = CGContext(
            data: &raw,
            width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: width * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue,
        ) else { return nil }
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))

        var pixels: [RGB] = []
        pixels.reserveCapacity(width * height)
        var index = 0
        while index + 2 < raw.count {
            let red = Double(raw[index]) / 255
            let green = Double(raw[index + 1]) / 255
            let blue = Double(raw[index + 2]) / 255
            pixels.append((r: red, g: green, b: blue))
            index += 4
        }
        return pixels
    }

    // MARK: - Color math

    private static func luminance(_ c: RGB) -> Double { 0.2126 * c.r + 0.7152 * c.g + 0.0722 * c.b }

    private static func saturation(_ c: RGB) -> Double {
        let high = max(c.r, c.g, c.b), low = min(c.r, c.g, c.b)
        return high <= 0 ? 0 : (high - low) / high
    }

    /// Colorfulness weighted by how much of the picture is that color, so a tone has to be both
    /// vivid and present to win.
    private static func accentScore(_ bucket: (count: Int, color: RGB), _ total: Double) -> Double {
        saturation(bucket.color) * pow(Double(bucket.count) / total, 0.35)
    }

    private static func scaled(_ c: RGB, _ factor: Double) -> RGB {
        (r: c.r * factor, g: c.g * factor, b: c.b * factor)
    }

    /// Raise a color to a target luminance, keeping its hue.
    private static func lighten(_ c: RGB, to target: Double) -> RGB {
        let current = luminance(c)
        guard current > 0.001 else { return (r: target, g: target, b: target) }
        guard current < target else { return c }
        let factor = target / current
        return (r: min(c.r * factor, 1), g: min(c.g * factor, 1), b: min(c.b * factor, 1))
    }

    /// Push a color away from its own grey, so an accent sampled from a hazy photograph still
    /// reads as a color once it is a 30pt chip in a tab bar.
    private static func saturate(_ c: RGB, by factor: Double) -> RGB {
        let grey = luminance(c)
        return (
            r: min(max(grey + (c.r - grey) * factor, 0), 1),
            g: min(max(grey + (c.g - grey) * factor, 0), 1),
            b: min(max(grey + (c.b - grey) * factor, 0), 1)
        )
    }

    private static func color(_ c: RGB, alpha: Double) -> GlassColor {
        GlassColor(red: c.r, green: c.g, blue: c.b, alpha: alpha)
    }
}
