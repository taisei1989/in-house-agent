import Foundation

@main
struct ConversationStoreCheck {
    static func main() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ConversationStore(directory: root)
        var answer = ChatMessage(user: false, text: "日本語の回答")
        answer.thought = "synthetic SDK output"
        answer.tools = [ToolActivity(id: "operation-1", name: "list_directory", status: "completed", result: "alpha.txt")]
        let record = ConversationRecord(id: UUID(), title: "確認", updatedAt: Date(), messages: [ChatMessage(user: true, text: "一覧"), answer], workspace: "/tmp/fixture", backend: "litert", model: "test")
        try store.save(record)
        let restored = try store.load()
        precondition(restored.count == 1 && restored[0].messages[1].tools[0].result == "alpha.txt")
        precondition(restored[0].messages[1].text == "日本語の回答")
        let attributes = try FileManager.default.attributesOfItem(atPath: root.appendingPathComponent(record.id.uuidString + ".json").path)
        precondition((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
        let link = root.appendingPathComponent(UUID().uuidString + ".json")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: root.appendingPathComponent(record.id.uuidString + ".json"))
        let excludingLinks = try store.load()
        precondition(excludingLinks.count == 1)
        let corrupt = root.appendingPathComponent(UUID().uuidString + ".json")
        try Data("invalid json".utf8).write(to: corrupt)
        var unreadable = false
        let recovered = try store.load { unreadable = true }
        precondition(unreadable && recovered.count == 1)
        try store.delete(record.id)
        let afterDelete = try store.load()
        precondition(afterDelete.isEmpty)
        print("PASS: Japanese transcript/tool roundtrip, private file permissions, symlink exclusion, corrupt-file isolation, deletion")
    }
}
