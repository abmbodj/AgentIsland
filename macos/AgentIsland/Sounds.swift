import AppKit

/// Optional cues (D21): a chime when an agent needs you, a softer one when a turn finishes.
/// Never when you're already looking at that session, and at most once every 10 s.
enum Sounds {
    enum Kind { case needsInput, finished }

    static let choices = ["Glass", "Ping", "Pop", "Tink", "Purr", "Bottle", "Blow", "Frog", "Hero", "Morse", "Submarine"]
    private static var last = Date.distantPast

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
        guard let s = NSSound(named: NSSound.Name(name(k)))?.copy() as? NSSound else { return }
        s.volume = volume
        s.play()
    }
}
