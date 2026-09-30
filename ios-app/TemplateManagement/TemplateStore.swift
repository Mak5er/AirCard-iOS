import Foundation

/// A missing store is a first launch; an unreadable store must never be replaced.
/// Kept outside the imported archive library so deleting a .tendies cannot lose ownership.
@MainActor
final class TemplateStore {
    let url: URL
    init(url: URL) { self.url = url }

    func load() throws -> [TemplateInstallation] {
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        let records = try JSONDecoder().decode([TemplateInstallation].self, from: Data(contentsOf: url))
        guard Set(records.map(\.id)).count == records.count else {
            throw TemplateFailure(message: "Duplicate installation records; the journal was left untouched.")
        }
        return records
    }

    func put(_ record: TemplateInstallation) throws {
        var records = try load()
        if let index = records.firstIndex(where: { $0.id == record.id }) {
            records[index] = record
        } else {
            records.append(record)
        }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(records).write(to: url, options: .atomic)
    }

    func libraryDeletionAllowed(fileName: String) throws -> Bool {
        try !load().contains { $0.fileName == fileName && $0.phase != .removed }
    }

    /// Return the journal bytes unchanged so a Files export can be kept before an app reinstall.
    func exportCopy() throws -> Data {
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw TemplateFailure(message: "There is no installation journal to export yet.")
        }
        return try Data(contentsOf: url)
    }
}
