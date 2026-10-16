import Foundation

/// What the Finder extension asks the app: compress the selected items, straight to a ZIP next to
/// them or through the New window. It travels as a `kompac://compress?…` URL: the sandboxed
/// extension can neither run 7zz on the user's files nor talk to the app in another way.
public struct FinderRequest: Equatable, Sendable {
    public enum Action: String, Sendable {
        /// ZIP, normal level, in the first item's folder, without asking anything.
        case zip
        /// Opens the New window with the items, to choose format, password and destination.
        case window
    }

    public static let scheme = "kompac"

    public var action: Action
    public var items: [URL]

    public init(action: Action, items: [URL]) {
        self.action = action
        self.items = items
    }

    /// Each path goes percent-encoded by hand: `queryItems` leaves "+", "&" and "=" as they are.
    private static let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789/-._~")

    public var url: URL {
        var c = URLComponents()
        c.scheme = Self.scheme
        c.host = "compress"
        c.percentEncodedQuery = (["action=" + action.rawValue] + items.map {
            "path=" + ($0.path.addingPercentEncoding(withAllowedCharacters: Self.allowed) ?? "")
        }).joined(separator: "&")
        return c.url!
    }

    /// nil for anything that is not a well-formed request: another host, unknown action, no items,
    /// or a path that is not absolute.
    public init?(url: URL) {
        guard url.scheme == Self.scheme, url.host == "compress",
              let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.percentEncodedQuery else { return nil }
        var action: Action?
        var items: [URL] = []
        for pair in query.split(separator: "&") {
            let kv = pair.split(separator: "=", maxSplits: 1).map(String.init)
            guard kv.count == 2, let value = kv[1].removingPercentEncoding else { return nil }
            switch kv[0] {
            case "action": action = Action(rawValue: value)
            case "path":
                guard value.hasPrefix("/") else { return nil }
                items.append(URL(fileURLWithPath: value).standardizedFileURL)
            default: return nil
            }
        }
        guard let action, !items.isEmpty else { return nil }
        self.init(action: action, items: items)
    }
}
