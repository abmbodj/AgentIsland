import AppKit

/// Optional cues (D21): a chime when an agent needs you, a softer one when a turn finishes.
/// Never when you're already looking at that session, and at most once every 10 s.
enum Sounds {
    enum Kind { case needsInput, finished }

    static let choices = ["Glass", "Ping", "Pop", "Tink", "Purr", "Bottle", "Blow", "Frog", "Hero", "Morse", "Submarine"]
    private static var last = Date.distantPast
    private static let playback = DispatchQueue(label: "island.sound", qos: .userInitiated)

    static func enabled(_ k: Kind) -> Bool {
        UserDefaults.standard.object(forKey: k == .needsInput ? "chimeNeedsInput" : "chimeFinished") as? Bool ?? true
    }

    static func name(_ k: Kind) -> String {
        UserDefaults.standard.string(forKey: k == .needsInput ? "soundNeedsInput" : "soundFinished") ?? (k == .needsInput ? "Glass" : "Tink")
    }

    static var volume: Float { UserDefaults.standard.object(forKey: "soundVolume") as? Float ?? 0.6 }

    static func play(_ k: Kind, preview: Bool = false) {
        guard preview || (enabled(k) && Date().timeIntervalSince(last) >= 10) else { return }
        if !preview { last = Date() }
        // First-use Core Audio initialization showed up in the main-thread profile.
        // Capture preferences now; all sound objects stay on this serial worker.
        let chosen = name(k), level = volume
        playback.async {
            autoreleasepool {
                guard let sound = NSSound(named: NSSound.Name(chosen))?.copy() as? NSSound else { return }
                sound.volume = level
                sound.play()
            }
        }
    }
}
