import Foundation

extension WorkTask {
    static func validatedPaths(_ paths: [String]) throws -> [String] {
        try Array(Set(paths.map { path in
            guard !path.hasPrefix("/") else { throw CoreError.invalid("Affected paths must be repository-relative.") }
            let path = path.trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            guard !path.isEmpty, !path.split(separator: "/").contains(".."), !path.hasPrefix("~") else { throw CoreError.invalid("Affected paths must be relative files or directories within the repository.") }
            return path.precomposedStringWithCanonicalMapping.lowercased()
        })).sorted()
    }
}
