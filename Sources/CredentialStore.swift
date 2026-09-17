import Foundation

enum CredentialStore {
    private static let fileManager = FileManager.default
    private static var secretsDirectory: URL {
        fileManager.urls(for:.applicationSupportDirectory,in:.userDomainMask)[0]
            .appendingPathComponent("XueScribe/Secrets",isDirectory:true)
    }
    private static var assemblyAIKeyURL: URL {
        secretsDirectory.appendingPathComponent("assemblyai.key",isDirectory:false)
    }

    static var hasAssemblyAIKey: Bool { assemblyAIKey() != nil }

    static func assemblyAIKey() -> String? {
        guard let data = try? Data(contentsOf:assemblyAIKeyURL),
              let key = String(data:data,encoding:.utf8)?.trimmingCharacters(in:.whitespacesAndNewlines),
              !key.isEmpty else { return nil }
        return key
    }

    static func saveAssemblyAIKey(_ rawKey: String) throws {
        let key = rawKey.trimmingCharacters(in:.whitespacesAndNewlines)
        guard !key.isEmpty else { try deleteAssemblyAIKey(); return }
        try fileManager.createDirectory(at:secretsDirectory,withIntermediateDirectories:true,
                                        attributes:[.posixPermissions:0o700])
        try fileManager.setAttributes([.posixPermissions:0o700],ofItemAtPath:secretsDirectory.path)
        try Data(key.utf8).write(to:assemblyAIKeyURL,options:.atomic)
        try fileManager.setAttributes([.posixPermissions:0o600],ofItemAtPath:assemblyAIKeyURL.path)
    }

    static func deleteAssemblyAIKey() throws {
        guard fileManager.fileExists(atPath:assemblyAIKeyURL.path) else { return }
        try fileManager.removeItem(at:assemblyAIKeyURL)
    }
}
