import Foundation

struct TemplateDevice: Codable, Equatable {
    var udid: String
    var name: String
    var model: String
    var container: String
}

struct TemplateOwnership: Codable, Equatable {
    var schema = 1
    var installationID: String
    var descriptorID: String
    var numericID: Int
    var udid: String
    var container: String

    enum CodingKeys: String, CodingKey {
        case schema, udid, container
        case installationID = "installationId"
        case descriptorID = "descriptorId"
        case numericID = "numericId"
    }
}

enum TemplatePhase: String, Codable {
    case installing, refreshPending, installed, removing, removed, needsAttention
}

enum TemplateAction: String, Codable { case install, remove }

struct TemplateInstallation: Codable, Identifiable, Equatable {
    var id: String { ownership.installationID }
    var ownership: TemplateOwnership
    var deviceName: String
    var name: String
    var fileName: String
    /// Primary provider first; the Collections migration copy is optional.
    var providers: [String]
    var date = Date()
    var phase: TemplatePhase = .installing
    var action: TemplateAction = .install
    var lastError: String?

    static func make(
        name: String, fileName: String, device: TemplateDevice,
        descriptorID: String, numericID: Int, provider: String
    ) -> Self {
        var providers = [provider]
        if provider == "com.apple.WallpaperKit.CollectionsPoster" {
            providers.append("com.apple.Posters.CollectionsPosterApp")
        }
        return Self(
            ownership: .init(
                installationID: UUID().uuidString, descriptorID: descriptorID,
                numericID: numericID, udid: device.udid, container: device.container),
            deviceName: device.name, name: name, fileName: fileName, providers: providers)
    }
}

struct TemplateFailure: LocalizedError {
    var message: String
    var errorDescription: String? { message }
}
