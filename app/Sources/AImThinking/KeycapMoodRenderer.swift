import AppKit

@MainActor
enum KeycapMoodRenderer {
    private struct Key: Hashable {
        let agent: AgentService
        let level: Int
        let frame: Int
        let state: KeycapIcon.State?
        let dark: Bool
        let highContrast: Bool
    }
    private static var cache: [Key: NSImage] = [:]
    static var cachedImageCount: Int { cache.count }
    static let cacheLimit = 240

    static func image(frame: Int, state: KeycapIcon.State?, mood: MoodAppearance?,
                      dark: Bool, highContrast: Bool) -> NSImage {
        guard let mood, mood.level > 0, state != .muted else {
            return KeycapIcon.image(frame: frame, state: state)
        }
        let key = Key(agent: mood.agent, level: min(MoodAppearance.levels, mood.level),
                      frame: frame, state: state, dark: dark, highContrast: highContrast)
        if let cached = cache[key] { return cached }
        let tint: NSColor = mood.agent == .claude
            ? NSColor(srgbRed: 0xD9 / 255, green: 0x77 / 255, blue: 0x57 / 255, alpha: 1)
            : NSColor(srgbRed: 0x35 / 255, green: 0xB6 / 255, blue: 0xAA / 255, alpha: 1)
        let neutral: NSColor = dark ? .black : .white
        // Keep a dark face dark enough for its small white label.
        let base = dark ? 0.08 : 0.2
        let spread = highContrast ? 0.3 : (dark ? 0.45 : 0.65)
        let fraction = base + spread * Double(key.level) / Double(MoodAppearance.levels)
        let color = neutral.blended(withFraction: fraction, of: tint) ?? tint
        let image = KeycapIcon.coloredImage(frame: frame, state: state, faceColor: color,
                                          foreground: dark ? .white : .black)
        if cache.count >= cacheLimit { cache.removeAll(keepingCapacity: true) }
        cache[key] = image
        return image
    }
}
