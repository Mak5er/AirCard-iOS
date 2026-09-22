import AirliftFFI
import Foundation

@MainActor
final class TendiesTemplateTransport: TemplateTransport {
    static var store: TemplateStore {
        let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return TemplateStore(url: root.appendingPathComponent("AirCard/installed-templates.json"))
    }

    private let pairingPath: String
    private let log: (String) -> Void
    init(pairingPath: String, log: @escaping (String) -> Void) {
        self.pairingPath = pairingPath
        self.log = log
    }

    private struct Request: Encodable {
        var action: String
        var ownership: TemplateOwnership?
        var provider: String?
        var folder: String?
    }
    private struct Presence: Decodable { var present: Bool }
    private struct Removal: Decodable { var removed: Bool }

    private func call<Result: Decodable>(_ request: Request, as type: Result.Type) async throws -> Result {
        let json = String(decoding: try JSONEncoder().encode(request), as: UTF8.self)
        let pairing = pairingPath
        let data: Data = try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                var output: UnsafeMutablePointer<CChar>?
                var error: UnsafeMutablePointer<CChar>?
                let rc = pairing.withCString { pair in
                    json.withCString { input in
                        al_template_operation(
                            pair, input,
                            { _, message in
                                guard let message else { return }
                                let line = String(cString: message)
                                DispatchQueue.main.async { AppViewModel.shared?.tendiesFlashLog.append(line) }
                            }, nil, &output, &error)
                    }
                }
                defer {
                    if let output { al_string_free(output) }
                    if let error { al_string_free(error) }
                }
                guard rc == 0, let output else {
                    continuation.resume(
                        throwing: TemplateFailure(
                            message: error.map { String(cString: $0) } ?? "Wallpaper operation failed."))
                    return
                }
                continuation.resume(returning: Data(String(cString: output).utf8))
            }
        }
        return try JSONDecoder().decode(type, from: data)
    }

    func context() async throws -> TemplateDevice {
        try await call(Request(action: "context"), as: TemplateDevice.self)
    }
    func install(_ record: TemplateInstallation, provider: String, folder: URL) async throws {
        let result = try await call(
            Request(action: "install", ownership: record.ownership, provider: provider, folder: folder.path),
            as: Presence.self)
        guard result.present else { throw TemplateFailure(message: "Template write was not confirmed.") }
    }
    func contains(_ record: TemplateInstallation, provider: String) async throws -> Bool {
        try await call(Request(action: "inspect", ownership: record.ownership, provider: provider), as: Presence.self)
            .present
    }
    func remove(_ record: TemplateInstallation, provider: String) async throws {
        let result = try await call(
            Request(action: "remove", ownership: record.ownership, provider: provider), as: Removal.self)
        guard result.removed else { throw TemplateFailure(message: "Template removal was not confirmed.") }
    }
    func refresh(_ device: TemplateDevice) async throws {
        let current = try await context()
        guard current.udid == device.udid, current.container == device.container else {
            throw TemplateFailure(message: "Device identity changed before the refresh.")
        }
        try await TendiesEngine.shared.refreshPosterBoard(
            containerPath: device.container, pairingPath: pairingPath, log: log)
    }
}
