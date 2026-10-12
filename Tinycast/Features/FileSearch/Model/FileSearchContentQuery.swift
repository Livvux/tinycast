import Foundation

/// What Search Files asks DigUp's `digup search` CLI, and how its JSON answer reads back.
enum FileSearchContentQuery {
    static let bundleIdentifier = "com.abdurrahim.DigUp"
    static let helperPath = "Contents/Helpers/digup"
    /// DigUp ranks segments, not files, so a few spare hits survive collapsing a file's pages.
    static let hitLimit = 40
    static let resultLimit = 20

    /// `nil` means the filter admits nothing DigUp indexes, so no process is started.
    static func kinds(for filter: FileSearchFilter) -> [String]? {
        switch filter {
        case .all: return []
        case .documents: return ["pdf", "doc"]
        case .images: return ["image", "screenshot"]
        case .audio: return ["audio"]
        case .video: return ["video"]
        case .folders, .archives: return nil
        }
    }

    static func arguments(for query: String, filter: FileSearchFilter) -> [String]? {
        guard !query.isEmpty, let kinds = kinds(for: filter) else { return nil }
        let kindArguments = kinds.isEmpty ? [] : ["--kind", kinds.joined(separator: ",")]
        // DigUp's parser has no "--", and a leading space is what keeps "-n" from reading as an option.
        let words = query.hasPrefix("-") ? " " + query : query
        return ["search", "-n", String(hitLimit), "--json"] + kindArguments + [words]
    }

    /// Paths in DigUp's rank order, each once; anything unreadable is no hits rather than a failure.
    static func paths(fromJSON data: Data) -> [String] {
        struct Hit: Decodable { let path: String }
        guard let hits = try? JSONDecoder().decode([Hit].self, from: data) else { return [] }
        var seen = Set<String>()
        return hits.map(\.path).filter { seen.insert($0).inserted }
    }
}
