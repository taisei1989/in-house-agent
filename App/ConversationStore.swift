import Foundation

struct ToolActivity: Identifiable, Codable {
    let id: String
    let name: String
    var status: String
    var args = ""
    var result = ""
    var error = ""
    var truncated = false
}

struct ChatMessage: Identifiable, Codable {
    var id = UUID()
    let user: Bool
    var text: String
    var thought = ""
    var thoughtTruncated = false
    var tools: [ToolActivity] = []
    var status = "completed"
    var failure: String?
    var createdAt = Date()
}

struct ConversationRecord: Identifiable, Codable {
    var id: UUID
    var title: String
    var updatedAt: Date
    var messages: [ChatMessage]
    var workspace: String
    var backend: String
    var model: String
}

/// Local transcripts only. These files are not SDK session checkpoints.
struct ConversationStore {
    let directory: URL
    func load(onUnreadable: () -> Void = {}) throws -> [ConversationRecord] {
        guard FileManager.default.fileExists(atPath: directory.path) else { return [] }
        return try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.isSymbolicLinkKey])
            .filter { $0.pathExtension == "json" && UUID(uuidString: $0.deletingPathExtension().lastPathComponent) != nil }
            .compactMap { url in
                do {
                guard (try url.resourceValues(forKeys: [.isSymbolicLinkKey])).isSymbolicLink != true else { return nil }
                var record = try JSONDecoder().decode(ConversationRecord.self, from: Data(contentsOf: url))
                for index in record.messages.indices {
                    if ["responding", "waiting"].contains(record.messages[index].status) { record.messages[index].status = "cancelled" }
                    for tool in record.messages[index].tools.indices where record.messages[index].tools[tool].status == "running" {
                        record.messages[index].tools[tool].status = "cancelled"
                    }
                }
                return record
                } catch { onUnreadable(); return nil }
            }.sorted { $0.updatedAt > $1.updatedAt }
    }
    func save(_ record: ConversationRecord) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        let url = directory.appendingPathComponent(record.id.uuidString + ".json")
        try JSONEncoder().encode(record).write(to: url, options: [.atomic, .completeFileProtectionUnlessOpen])
        try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
    func delete(_ id: UUID) throws {
        let url = directory.appendingPathComponent(id.uuidString + ".json")
        if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
    }
}
