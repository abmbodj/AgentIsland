import Foundation
import Combine

/// Local labels only: never changes the agent's project, transcript or working directory.
/// Loaded on first panel opening, with writes only when the user saves a name.
final class SessionTitles: ObservableObject {
    static let shared = SessionTitles()
    @Published private var names: [String: String] = [:]
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
        keys.compactMap { names[$0] }.first ?? (fallback.isEmpty ? "Session" : fallback)
    }

    func save(_ text: String, for keys: [String]) {
        load()
        let value = String(text.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ").prefix(120))
        for key in keys { names[key] = value.isEmpty ? nil : value }
        defaults.set(names, forKey: storageKey)
    }
}
