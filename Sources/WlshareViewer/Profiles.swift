import CryptoKit
import Foundation
import Security

/// A saved desktop: what the form holds, under a name — and the password only
/// when it was asked to keep one, and then sealed, never in the clear.
struct Profile: Codable, Equatable, Identifiable {
    var id = UUID()
    var name = ""
    var host = ""
    var port: UInt16 = 5900
    var username = ""
    var audio = false
    var encoding: Encoding = .vp9
    /// Whether the form's **Save the password** is ticked for this one.
    var savesPassword = false
    /// The password, sealed by `SafeStorage` with this profile's id bound in.
    /// Nil is none saved, which a ticked checkbox with nothing typed also is.
    var sealedPassword: Data?

    /// What the list shows in bold: the name, or where it goes when it has none.
    var title: String {
        if !name.isEmpty { return name }
        return host.isEmpty ? "New Desktop" : "\(host):\(port)"
    }

    /// What the list shows under the title: who goes where, less whatever
    /// the title already says. Empty for a profile with only a host and port.
    var address: String {
        guard !host.isEmpty else { return "" }
        if name.isEmpty { return username }
        return username.isEmpty ? "\(host):\(port)" : "\(username)@\(host):\(port)"
    }

    /// The saved password, opened; nil when none is saved.
    @MainActor
    func password() throws -> String? {
        try sealedPassword.map { try SafeStorage.open($0, for: id) }
    }

    func destination(password: String) -> Destination {
        Destination(host: host, port: port, username: username, password: password, audio: audio, encoding: encoding)
    }
}

extension Profile {
    /// A profile not saved yet, filled with a destination from somewhere else.
    init(_ destination: Destination) {
        self.init(
            host: destination.host,
            port: destination.port,
            username: destination.username,
            audio: destination.audio,
            encoding: destination.encoding
        )
    }
}

/// The saved profiles, in the order the list shows them, and which one the form
/// was last showing.
///
/// A `defaults` plist is a file, and that is all right here: the only secret in
/// a profile is sealed, and the key that opens it is in the keychain.
@MainActor
final class ProfileStore {
    private(set) var profiles: [Profile]

    init() {
        let data = UserDefaults.standard.data(forKey: Key.profiles) ?? Data()
        profiles = (try? JSONDecoder().decode([Profile].self, from: data)) ?? []
    }

    /// The one the form was showing when the app was last used.
    var selected: UUID? {
        get { UserDefaults.standard.string(forKey: Key.selected).flatMap(UUID.init(uuidString:)) }
        set { UserDefaults.standard.set(newValue?.uuidString, forKey: Key.selected) }
    }

    func profile(_ id: UUID) -> Profile? {
        profiles.first { $0.id == id }
    }

    func index(of id: UUID) -> Int? {
        profiles.firstIndex { $0.id == id }
    }

    /// The first profile that goes where `destination` does, as the same user:
    /// what a `-server` launch takes a saved password from.
    func profile(matching destination: Destination) -> Profile? {
        profiles.first {
            $0.host == destination.host && $0.port == destination.port && $0.username == destination.username
        }
    }

    /// Save `profile`, over the one with its id or after the rest.
    func put(_ profile: Profile) {
        if let index = index(of: profile.id) {
            profiles[index] = profile
        } else {
            profiles.append(profile)
        }
        write()
    }

    /// Put `id` at `index` in the list, the rest keeping their order.
    func move(_ id: UUID, to index: Int) {
        guard let from = self.index(of: id) else { return }
        profiles.insert(profiles.remove(at: from), at: index)
        write()
    }

    func remove(_ id: UUID) {
        profiles.removeAll { $0.id == id }
        if selected == id { selected = nil }
        write()
    }

    private func write() {
        // Encoding plain values into JSON does not fail.
        let data = try! JSONEncoder().encode(profiles)
        UserDefaults.standard.set(data, forKey: Key.profiles)
    }

    /// Not argument names, which outrank anything written to the standard
    /// domain.
    private enum Key {
        static let profiles = "connectionProfiles"
        static let selected = "selectedProfile"
    }
}

/// Saved passwords the way Chrome and Slack keep theirs: one random key in the
/// keychain — the only item this app puts there — and every password sealed
/// with it where the profiles are.
///
/// One item rather than one per password is what makes the keychain bearable
/// for an app that is ad-hoc signed: every new build is a new signature, and
/// macOS asks again for each item a new signature reads. With one key it asks
/// once per build, not once per desktop.
///
/// A password is sealed with AES-GCM and the profile's id as associated data,
/// so a sealed password copied onto another profile does not open.
@MainActor
enum SafeStorage {
    static let service = "WlshareViewer Safe Storage"
    static let account = "WlshareViewer"

    /// Read at most once a launch: every read is a question macOS may ask.
    private static var key: SymmetricKey?

    enum Failure: LocalizedError {
        case keychain(OSStatus)
        case noKey
        case badKey
        case unreadable

        var errorDescription: String? {
            switch self {
            case .keychain(let status):
                let reason = SecCopyErrorMessageString(status, nil).map { $0 as String } ?? "error \(status)"
                return "The keychain would not give up the key to saved passwords: \(reason)"
            case .noKey:
                return "The key to saved passwords is gone from the keychain; type the password again."
            case .badKey:
                return "The key to saved passwords in the keychain is not one this app made."
            case .unreadable:
                return "The saved password does not open with the keychain's key; type it again."
            }
        }
    }

    static func seal(_ password: String, for id: UUID) throws -> Data {
        let sealed = try AES.GCM.seal(Data(password.utf8), using: masterKey(creating: true), authenticating: Data(id.uuidString.utf8))
        // A random 96-bit nonce always gives the combined form.
        return sealed.combined!
    }

    static func open(_ sealed: Data, for id: UUID) throws -> String {
        let key = try masterKey(creating: false)
        do {
            let box = try AES.GCM.SealedBox(combined: sealed)
            let plain = try AES.GCM.open(box, using: key, authenticating: Data(id.uuidString.utf8))
            return String(decoding: plain, as: UTF8.self)
        } catch {
            throw Failure.unreadable
        }
    }

    /// The key, from the keychain — made and put there by the first password
    /// saved, and never by a read: a key made when the old one is missing
    /// opens nothing the old one sealed.
    private static func masterKey(creating: Bool) throws -> SymmetricKey {
        if let key { return key }
        var query = item
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var found: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &found)
        switch status {
        case errSecSuccess:
            // Kept as base64 text, as Chrome keeps its own, so the item reads
            // as an ordinary password in Keychain Access.
            guard let text = found as? Data, let raw = Data(base64Encoded: text), raw.count == 32 else {
                throw Failure.badKey
            }
            key = SymmetricKey(data: raw)
        case errSecItemNotFound:
            guard creating else { throw Failure.noKey }
            let made = SymmetricKey(size: .bits256)
            var adding = item
            adding[kSecValueData as String] = made.withUnsafeBytes { Data($0) }.base64EncodedData()
            adding[kSecAttrLabel as String] = service
            adding[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlocked
            let added = SecItemAdd(adding as CFDictionary, nil)
            guard added == errSecSuccess else { throw Failure.keychain(added) }
            key = made
        default:
            throw Failure.keychain(status)
        }
        return key!
    }

    /// A generic item with no access group and no sharing: it belongs to this
    /// app on this Mac.
    private static var item: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }
}
