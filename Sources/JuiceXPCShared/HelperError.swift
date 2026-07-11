import Foundation

/// Typed errors crossing the XPC boundary from the helper to the app.
public enum HelperError {
    /// The NSError domain used for all helper errors.
    public static let domain = "\(JuiceXPC.helperLabel).error"

    /// Error codes within ``domain``.
    public enum Code: Int, Sendable {
        /// The powerlog database exists but its schema does not match
        /// what the reader expects. Never guess; refuse to query.
        case schemaMismatch = 1
        /// The powerlog database file is missing or unreadable.
        case powerlogUnavailable = 2
        /// The database (or its snapshot) reported SQLITE_BUSY/LOCKED.
        case databaseBusy = 3
        /// Any other internal failure.
        case internalError = 4
    }

    /// Builds an NSError in the helper error domain with a human-readable
    /// message stored under NSLocalizedDescriptionKey.
    public static func error(_ code: Code, message: String) -> NSError {
        NSError(
            domain: domain,
            code: code.rawValue,
            userInfo: [NSLocalizedDescriptionKey: message]
        )
    }

    /// Returns the typed code if `error` belongs to the helper domain.
    public static func code(of error: Error) -> Code? {
        let nsError = error as NSError
        guard nsError.domain == domain else { return nil }
        return Code(rawValue: nsError.code)
    }
}
