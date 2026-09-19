import Foundation

/// How the desktop's pixels are to arrive.
enum Encoding: String, Codable {
    /// wlshare's VP9 stream: the whole desktop, 4:4:4, at the quality the
    /// server sets. The default: small and smooth when the desktop moves. A
    /// server without it is an error, not a fallback to ZRLE.
    case vp9
    /// ZRLE: every pixel exactly as the desktop drew it.
    case zrle
}

/// A desktop to connect to: what one session is opened with. What is kept
/// between launches is a `Profile`.
struct Destination: Equatable {
    var host: String = ""
    var port: UInt16 = 5900
    var username: String = ""
    var password: String = ""
    /// Ask for the desktop's sound. A server without it gives none either way.
    var audio: Bool = false
    var encoding: Encoding = .vp9

    var label: String { "\(host):\(port)" }

    /// The command line, for a launch that came from a shell:
    ///
    ///     WlshareViewer -server 127.0.0.1:5999 -username me -audio YES -encoding zrle
    ///
    /// `UserDefaults` reads `-key value` pairs off the argument list, so the
    /// same words work through `open --args`. Nil when no `-server` was given,
    /// which is every launch from the Finder — those get the form.
    ///
    /// The password is not one of the words, and deliberately: an argument list
    /// is in the shell's history and in everyone's `ps`. A saved one comes from
    /// the profile that goes to the same place as the same user; anything else
    /// is typed into the form, which is what a refused connection brings back.
    static func fromArguments() -> Destination? {
        let defaults = UserDefaults.standard
        guard let server = defaults.string(forKey: "server") else { return nil }
        let (host, port) = split(server)
        return Destination(
            host: host,
            port: port,
            username: defaults.string(forKey: "username") ?? "",
            audio: defaults.bool(forKey: "audio"),
            encoding: Encoding(rawValue: defaults.string(forKey: "encoding") ?? "") ?? .vp9
        )
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
}
