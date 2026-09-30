import Foundation

@MainActor
protocol TemplateTransport {
    func context() async throws -> TemplateDevice
    func install(_ record: TemplateInstallation, provider: String, folder: URL) async throws
    func contains(_ record: TemplateInstallation, provider: String) async throws -> Bool
    func remove(_ record: TemplateInstallation, provider: String) async throws
    func refresh(_ device: TemplateDevice) async throws
}
