import Foundation
import GhosttyKit

/// Wraps UserDefaults to persist GUI settings overrides.
class SettingsStore {
    static let shared = SettingsStore()

    /// The UserDefaults domain prefix for all GUI settings keys.
    // TODO: JW: Could support more granular grouping?
    private static let keyPrefix = "ghostty."

    private let defaults = UserDefaults.standard

    // MARK: - Read

    /// Returns the stored value for a config key, or nil if not set
    func get(_ key: String) -> String? {
        return defaults.string(forKey: Self.keyPrefix + key)
    }

    /// Returns true if exists in UserDefaults
    ///
    /// Used to determine default vs custom config in the UI
    func isSet(_ key: String) -> Bool {
        return defaults.object(forKey: Self.keyPrefix + key) != nil
    }

    /// Returns all stored configuration options as a dictionary.
    func allOverrides() -> [String: String] {
        var result: [String: String] = [:]
        let allKeys = defaults.dictionaryRepresentation().keys
        for prefixedKey in allKeys {
            guard prefixedKey.hasPrefix(Self.keyPrefix) else { continue }
            let key = String(prefixedKey.dropFirst(Self.keyPrefix.count))
            if let value = defaults.string(forKey: prefixedKey) {
                result[key] = value
            }
        }
        return result
    }

    // MARK: - Write

    /// Saves a configuration option
    func save(_ key: String, value: String) {
        defaults.set(value, forKey: Self.keyPrefix + key)
    }

    /// Removes a stored configuration option
    func remove(_ key: String) {
        defaults.removeObject(forKey: Self.keyPrefix + key)
    }

    /// Removes all custom configuration options
    ///
    /// Serves as a 'Reset' back to default values
    func removeAll() {
        let allKeys = defaults.dictionaryRepresentation().keys
        for prefixedKey in allKeys {
            guard prefixedKey.hasPrefix(Self.keyPrefix) else { continue }
            defaults.removeObject(forKey: prefixedKey)
        }
    }

    // MARK: - Config Loading

    /// Builds a formatted string from stored configuration
    ///
    /// Example output:
    /// ```
    /// font-family = JetBrains Mono
    /// cursor-style = bar
    /// window-step-resize = true
    /// ```
    func buildConfigString() -> String {
        let overrides = allOverrides()
        guard !overrides.isEmpty else { return "" }

        var lines: [String] = []
        for (key, value) in overrides {
            lines.append("\(key) = \(value)")
        }
        return lines.joined(separator: "\n")
    }

    // MARK: - Reading Current Values from Config

    /// Reads the current value of a config key from a C API config object,
    /// returned as a string regardless of the underlying type.
    ///
    /// This uses the C API's formatter to convert any config value to its
    /// string representation, which is the same format used in config files.
    ///
    /// - Parameters:
    ///   - config: A finalized `ghostty_config_t`
    ///   - key: The config key name (e.g. "font-family")
    /// - Returns: The current value as a string, or "" if the key is invalid
    static func readValue(
        from config: ghostty_config_t,
        key: String
    ) -> String {
        guard
            let cStr = ghostty_config_get_string(config, key, UInt(key.lengthOfBytes(using: .utf8)))
        else {
            return ""
        }
        let result = String(cString: cStr)
        ghostty_config_free_string(cStr)
        return result
    }
}
