import CoreServices
import Foundation

/// Content matches from DigUp's own index, through the CLI it ships. Tinycast indexes nothing.
enum FileSearchContentService {
    /// No DigUp, a filter it can't answer, or a failed run is no hits: the filename rows stand alone.
    nonisolated static func search(
        query: String, filter: FileSearchFilter, policy: FileSearchPolicy
    ) async throws -> [FileSearchResult] {
        guard let arguments = FileSearchContentQuery.arguments(for: query, filter: filter),
            let executable = helperURL()
        else { return [] }
        let data = try await run(executable, arguments: arguments)
        return FileSearchContentQuery.paths(fromJSON: data)
            .lazy
            .filter { !FileSearchQuery.isExcludedPath($0, ignoring: policy.ignore) }
            .compactMap { FileSearchService.resolve($0, homeDirectory: policy.homeDirectory) }
            .filter { !$0.isDirectory }
            .prefix(FileSearchContentQuery.resultLimit)
            .map { $0 }
    }

    private nonisolated static func helperURL() -> URL? {
        guard
            let apps = LSCopyApplicationURLsForBundleIdentifier(
                FileSearchContentQuery.bundleIdentifier as CFString, nil)?
                .takeRetainedValue() as? [URL]
        else { return nil }
        return apps.lazy
            .map { $0.appending(path: FileSearchContentQuery.helperPath) }
            .first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    /// Cancelling the caller terminates the helper, so a superseded query stops encoding at once.
    private nonisolated static func run(_ executable: URL, arguments: [String]) async throws -> Data {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        return try await withTaskCancellationHandler {
            try await Task.detached(priority: .userInitiated) {
                try process.run()
                // Read before waiting: a full pipe would otherwise block the helper forever.
                let data = try output.fileHandleForReading.readToEnd() ?? Data()
                process.waitUntilExit()
                return process.terminationStatus == 0 ? data : Data()
            }.value
        } onCancel: {
            if process.isRunning { process.terminate() }
        }
    }
}
