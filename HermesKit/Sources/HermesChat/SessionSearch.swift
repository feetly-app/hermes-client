import Foundation
import HermesAPI

extension Array where Element == RemoteSession {
    /// The sessions whose shown title (`displayTitle`) contains `query`, ignoring case and accents, in the same
    /// order. A query made only of whitespace keeps every session.
    public func matching(_ query: String) -> [RemoteSession] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return self }
        return filter {
            $0.displayTitle.range(of: needle, options: [.caseInsensitive, .diacriticInsensitive]) != nil
        }
    }
}

extension Array where Element == Project {
    /// The projects whose name contains `query`, ignoring case and accents, in the same order. A query made only
    /// of whitespace keeps every project. The conversations inside projects are not searched.
    public func matching(_ query: String) -> [Project] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return self }
        return filter {
            $0.name.range(of: needle, options: [.caseInsensitive, .diacriticInsensitive]) != nil
        }
    }
}
