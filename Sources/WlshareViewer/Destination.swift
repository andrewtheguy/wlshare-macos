import Foundation
import Security

/// A desktop to connect to, and what is remembered about it between launches.
///
/// The host, the port and the user name are preferences; the password is not,
/// and goes to the keychain or nowhere. Nothing is remembered unless the
/// dialog's checkbox says so.
struct Destination: Equatable {
    var host: String = ""
    var port: UInt16 = 5900
    var username: String = ""
    var password: String = ""
    var remember: Bool = false

    var label: String { "\(host):\(port)" }

    /// What the keychain calls this, which is the destination without the
    /// secret: a different user on the same desktop is a different password.
    private var account: String { "\(username)@\(host):\(port)" }

    /// The command line, for a launch that came from a shell:
    ///
    ///     WlshareViewer -server 127.0.0.1:5999 -username me
    ///
    /// `UserDefaults` reads `-key value` pairs off the argument list, so the
    /// same words work through `open --args`. Nil when no `-server` was given,
    /// which is every launch from the Finder — those get the dialog.
    ///
    /// The password is not one of the words, and deliberately: an argument list
    /// is in the shell's history and in everyone's `ps`. A remembered one comes
    /// from the keychain; anything else is typed into the dialog, which is what
    /// a refused connection brings back.
    static func fromArguments() -> Destination? {
        let defaults = UserDefaults.standard
        guard let server = defaults.string(forKey: "server") else { return nil }
        let (host, port) = split(server)
        var destination = Destination(host: host, port: port, username: defaults.string(forKey: "username") ?? "")
        destination.password = Keychain.password(account: destination.account) ?? ""
        destination.remember = !destination.password.isEmpty
        return destination
    }

    /// What the dialog opens filled with.
    static func remembered() -> Destination {
        let defaults = UserDefaults.standard
        var destination = Destination(
            host: defaults.string(forKey: Key.host) ?? "",
            port: UInt16(exactly: defaults.integer(forKey: Key.port)) ?? 5900,
            username: defaults.string(forKey: Key.username) ?? "",
            remember: defaults.bool(forKey: Key.remember)
        )
        if destination.port == 0 { destination.port = 5900 }
        if destination.remember {
            destination.password = Keychain.password(account: destination.account) ?? ""
        }
        return destination
    }

    /// Remember this one — or, with the checkbox off, stop remembering the
    /// password for it.
    func save() {
        let defaults = UserDefaults.standard
        defaults.set(host, forKey: Key.host)
        defaults.set(Int(port), forKey: Key.port)
        defaults.set(username, forKey: Key.username)
        defaults.set(remember, forKey: Key.remember)
        if remember, !password.isEmpty {
            Keychain.set(password, account: account)
        } else {
            Keychain.remove(account: account)
        }
    }

    /// `host:port`, `host`, or an IPv6 literal in brackets.
    static func split(_ server: String) -> (String, UInt16) {
        if server.hasPrefix("["), let end = server.firstIndex(of: "]") {
            let host = String(server[server.index(after: server.startIndex)..<end])
            let rest = server[server.index(after: end)...]
            return (host, UInt16(rest.dropFirst()) ?? 5900)
        }
        guard let colon = server.lastIndex(of: ":"), let port = UInt16(server[server.index(after: colon)...]) else {
            return (server, 5900)
        }
        return (String(server[..<colon]), port)
    }

    /// Deliberately not `server` or `username`: those are the argument names,
    /// and the argument domain outranks anything written here.
    private enum Key {
        static let host = "lastHost"
        static let port = "lastPort"
        static let username = "lastUsername"
        static let remember = "rememberPassword"
    }
}

/// The password, and only the password. A generic item with no access group and
/// no sharing: it belongs to this app on this Mac.
private enum Keychain {
    static let service = "dev.andrewtheguy.wlshareviewer"

    static func password(account: String) -> String? {
        var query = item(account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var found: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &found) == errSecSuccess,
              let data = found as? Data
        else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    static func set(_ password: String, account: String) {
        // Written rather than updated: one delete and one add is the same two
        // calls an update would cost when the item is not there yet.
        SecItemDelete(item(account) as CFDictionary)
        var adding = item(account)
        adding[kSecValueData as String] = Data(password.utf8)
        adding[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlocked
        SecItemAdd(adding as CFDictionary, nil)
    }

    static func remove(account: String) {
        SecItemDelete(item(account) as CFDictionary)
    }

    private static func item(_ account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }
}
