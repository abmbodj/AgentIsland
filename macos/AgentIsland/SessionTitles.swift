import Foundation
import Combine

/// Local labels only: never changes the agent's project, transcript or working directory.
/// Loaded on first panel opening, with writes only when the user saves a name.
final class SessionTitles: ObservableObject {
    static let shared = SessionTitles()
    @Published private var names: [String: String] = [:]
    @Published private var provisional: [String: String] = [:]
    private var links: [String: String] = [:]
    private var loaded = false
    private let defaults: UserDefaults
    private let storageKey = "sessionTitles"

    init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    func load() {
        guard !loaded else { return }
        loaded = true
        names = defaults.dictionary(forKey: storageKey) as? [String: String] ?? [:]
    }

    func title(for keys: [String], fallback: String) -> String {
        keys.compactMap { names[links[$0] ?? $0] ?? provisional[$0] }.first ?? (fallback.isEmpty ? "Session" : fallback)
    }

    func save(_ text: String, for keys: [String]) {
        load()
        let value = String(text.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ").prefix(120))
        for original in keys {
            let key = links[original] ?? original
            if key.hasPrefix("chat:") { provisional[key] = value.isEmpty ? nil : value }
            else { names[key] = value.isEmpty ? nil : value }
        }
        defaults.set(names, forKey: storageKey)
    }

    /// Core chat numbers restart at 1 each launch. Only agent session IDs are durable.
    /// Remember the link so saving an editor opened before identification also uses the durable key.
    func link(temporary: String, session: String) {
        guard links[temporary] != session else { return }
        load()
        objectWillChange.send()
        links[temporary] = session
        if let name = provisional.removeValue(forKey: temporary), names[session] == nil {
            names[session] = name
            defaults.set(names, forKey: storageKey)
        }
    }
}
