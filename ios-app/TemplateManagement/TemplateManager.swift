import Foundation

/// Writes intent before the first device mutation and retains it after every failure.
@MainActor
final class TemplateManager {
    let store: TemplateStore
    let transport: any TemplateTransport
    let log: (String) -> Void

    init(store: TemplateStore, transport: any TemplateTransport, log: @escaping (String) -> Void = { _ in }) {
        self.store = store
        self.transport = transport
        self.log = log
    }

    private func requireDevice(_ record: TemplateInstallation) async throws -> TemplateDevice {
        let device = try await transport.context()
        guard device.udid == record.ownership.udid, device.container == record.ownership.container else {
            throw TemplateFailure(
                message: "This record belongs to a different device or PosterBoard container. Nothing was changed.")
        }
        return device
    }

    private func failed(_ record: TemplateInstallation, _ error: Error) throws {
        var record = record
        record.phase = .needsAttention
        record.lastError = error.localizedDescription
        try store.put(record)
    }

    func stage(_ original: TemplateInstallation, folder: URL) async throws {
        _ = try await requireDevice(original)
        guard !original.providers.isEmpty, !(try store.load()).contains(where: { $0.id == original.id }) else {
            throw TemplateFailure(message: "Invalid or duplicate installation record.")
        }
        var record = original
        record.phase = .installing
        try store.put(record)
        do {
            let encoder = JSONEncoder()
            try encoder.encode(record.ownership).write(
                to: folder.appendingPathComponent("aircard-template-receipt.json"), options: .atomic)
            for (index, provider) in record.providers.enumerated() {
                do { try await transport.install(record, provider: provider, folder: folder) } catch {
                    if index == 0 { throw error }
                    log(
                        "Optional migration copy: \(error.localizedDescription). Its UUID remains recorded for removal."
                    )
                }
            }
            record.phase = .refreshPending
            try store.put(record)
        } catch {
            try failed(record, error)
            throw error
        }
    }

    func finishInstalls(_ ids: Set<String>) async throws {
        let records = try store.load().filter { ids.contains($0.id) }
        guard !records.isEmpty, records.count == ids.count,
            records.allSatisfy({ $0.action == .install && $0.phase != .removed })
        else {
            throw TemplateFailure(message: "Installation records are missing or no longer eligible for refresh.")
        }
        do {
            let device = try await requireDevice(records[0])
            for record in records {
                guard record.ownership.udid == device.udid, record.ownership.container == device.container,
                    let primary = record.providers.first
                else {
                    throw TemplateFailure(message: "Cannot refresh records from different devices.")
                }
                guard try await transport.contains(record, provider: primary) else {
                    throw TemplateFailure(
                        message:
                            "The template is absent from the device. Use Remove to clear this installation record, then import again."
                    )
                }
            }
            try await transport.refresh(device)
            for var record in records {
                record.phase = .installed
                record.lastError = nil
                try store.put(record)
            }
        } catch {
            for record in records { try failed(record, error) }
            throw error
        }
    }

    func remove(id: String) async throws {
        guard var record = try store.load().first(where: { $0.id == id }) else {
            throw TemplateFailure(message: "Installation record not found.")
        }
        if record.phase == .removed { return }
        let device = try await requireDevice(record)
        record.phase = .removing
        record.action = .remove
        record.lastError = nil
        try store.put(record)
        do {
            for provider in record.providers {
                try await transport.remove(record, provider: provider)
            }
            // Same fixed AirCard preference payload on install and remove. No snapshots or LIFO.
            record.phase = .refreshPending
            try store.put(record)
            try await transport.refresh(device)
            record.phase = .removed
            try store.put(record)
        } catch {
            try failed(record, error)
            throw error
        }
    }

    func verifyCurrentDevice() async throws -> TemplateDevice {
        let device = try await transport.context()
        for var record in try store.load()
        where record.phase == .installed
            && record.ownership.udid == device.udid && record.ownership.container == device.container
        {
            guard let primary = record.providers.first else { continue }
            if try await !transport.contains(record, provider: primary) {
                record.phase = .needsAttention
                record.lastError = "The template disappeared after refresh. Remove this record before importing again."
                try store.put(record)
            }
        }
        return device
    }
}
