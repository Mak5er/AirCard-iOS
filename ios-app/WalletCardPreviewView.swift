import SwiftUI
import UIKit
import UniformTypeIdentifiers

private struct WalletShareItem: Identifiable {
    let id = UUID()
    let url: URL
}

/// Wallet card tile with provider identity, current Wallet preview, backup maintenance,
/// per-card operation state, and recovery diagnostics.
struct WalletCardPreviewView: View {
    @EnvironmentObject var vm: AppViewModel
    @ObservedObject private var operationStore = WalletCardOperationStore.shared

    let card: CardItem
    let cardIndex: Int
    let onToggleSelected: (Bool) -> Void
    let onPickImage: () -> Void
    let onClearImage: () -> Void
    let onDelete: () -> Void

    @State private var copied = false
    @State private var shareItem: WalletShareItem? = nil
    @State private var showBackupImporter = false
    @State private var showRecovery = false

    var body: some View {
        let customImage = card.uiImage
        let renderedWalletPreview = AppViewModel.renderedWalletReferenceImage(for: card.id)
        let rawWalletPreview = AppViewModel.scannedCardPreviewImage(for: card.id)
        let walletPreview = renderedWalletPreview ?? rawWalletPreview
        let displayImage = customImage ?? walletPreview
        let logo = AppViewModel.scannedCardLogoImage(for: card.id)
        let metadata = AppViewModel.scannedCardMetadata(for: card.id)
        let backupValidation = AppViewModel.validateOriginalArtworkBackup(for: card.id)
        let recoveryCount = AppViewModel.walletRecoveryItems(for: card.id).count
        let phase = operationStore.phase(for: card.id)

        VStack(spacing: 12) {
            identityHeader(
                logo: logo,
                metadata: metadata,
                backupValidation: backupValidation,
                recoveryCount: recoveryCount
            )

            artworkCard(customImage: customImage, displayImage: displayImage)

            if let label = phase.label {
                HStack(spacing: 7) {
                    Image(systemName: phase.systemImage)
                    Text(label).lineLimit(1)
                    Spacer()
                }
                .font(.caption.bold())
                .foregroundStyle(phase.isFailure ? Color.red : Color.secondary)
                .padding(.horizontal, 9)
            }

            controlsRow(
                backupValidation: backupValidation,
                recoveryCount: recoveryCount
            )
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(Color(uiColor: .secondarySystemGroupedBackground))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .stroke(card.isSelected ? Color.blue.opacity(0.35) : Color.clear, lineWidth: 1.5)
        )
        .sheet(item: $shareItem) { item in
            ShareSheet(items: [item.url])
        }
        .fileImporter(
            isPresented: $showBackupImporter,
            allowedContentTypes: [UTType(filenameExtension: "aircardbackup") ?? .data],
            allowsMultipleSelection: false
        ) { result in
            do {
                guard let url = try result.get().first else { return }
                try vm.importOriginalArtworkBackup(from: url, for: card.id)
                vm.successAlertMessage = "Original-artwork backup imported and verified."
                vm.showSuccessAlert = true
            } catch {
                vm.errorMessage = "Backup import failed: \(error.localizedDescription)"
            }
        }
        .sheet(isPresented: $showRecovery) {
            WalletRecoveryDiagnosticsView(cardId: card.id)
                .environmentObject(vm)
        }
    }

    @ViewBuilder
    private func identityHeader(
        logo: UIImage?,
        metadata: WalletCardMetadata?,
        backupValidation: OriginalArtworkBackupValidation,
        recoveryCount: Int
    ) -> some View {
        HStack(spacing: 10) {
            if let logo {
                Image(uiImage: logo)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 38, height: 38)
                    .padding(5)
                    .background(Color(uiColor: .tertiarySystemBackground))
                    .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
            } else {
                Image(systemName: "creditcard.fill")
                    .font(.system(size: 20))
                    .foregroundStyle(.secondary)
                    .frame(width: 38, height: 38)
                    .background(Color(uiColor: .tertiarySystemBackground))
                    .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(metadata?.displayName ?? "Card #\(cardIndex + 1)")
                    .font(.subheadline.bold())
                    .lineLimit(1)
                if let secondary = metadata?.secondaryName {
                    Text(secondary)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                } else {
                    Text(card.id.prefix(10) + "…")
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                }
            }

            Spacer()

            Menu {
                Button {
                    vm.refreshScannedCardPreview(for: card.id)
                } label: {
                    Label("Refresh Wallet Preview", systemImage: "arrow.clockwise")
                }

                Divider()

                Button {
                    do {
                        shareItem = WalletShareItem(
                            url: try AppViewModel.exportOriginalArtworkBackup(for: card.id)
                        )
                    } catch {
                        vm.errorMessage = error.localizedDescription
                    }
                } label: {
                    Label("Export Original Backup", systemImage: "square.and.arrow.up")
                }
                .disabled(!backupValidation.isValid)

                Button {
                    showBackupImporter = true
                } label: {
                    Label("Import Original Backup", systemImage: "square.and.arrow.down")
                }

                Divider()

                Button {
                    showRecovery = true
                } label: {
                    Label(
                        recoveryCount > 0 ? "Recovery Diagnostics (\(recoveryCount))" : "Recovery Diagnostics",
                        systemImage: recoveryCount > 0 ? "lifepreserver.fill" : "lifepreserver"
                    )
                }
            } label: {
                Image(systemName: "ellipsis.circle")
                    .font(.title3)
            }
        }
    }

    @ViewBuilder
    private func artworkCard(customImage: UIImage?, displayImage: UIImage?) -> some View {
        GeometryReader { geo in
            let width = geo.size.width
            let height = width / 1.586

            ZStack {
                if let image = displayImage {
                    ZStack(alignment: .topTrailing) {
                        Image(uiImage: image)
                            .resizable()
                            .scaledToFill()
                            .frame(width: width, height: height)
                            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))

                        LinearGradient(
                            colors: [.white.opacity(0.18), .clear, .black.opacity(0.12)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))

                        if customImage != nil {
                            Button(action: onClearImage) {
                                Image(systemName: "xmark.circle.fill")
                                    .font(.system(size: 24))
                                    .foregroundStyle(.white.opacity(0.95))
                                    .background(Circle().fill(Color.black.opacity(0.55)))
                            }
                            .buttonStyle(.plain)
                            .padding(10)
                        } else {
                            Label("Wallet", systemImage: "creditcard.fill")
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundStyle(.white)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 5)
                                .background(.black.opacity(0.48))
                                .clipShape(Capsule())
                                .padding(10)
                        }
                    }
                } else {
                    ZStack {
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .fill(
                                LinearGradient(
                                    colors: [
                                        Color(uiColor: .secondarySystemBackground),
                                        Color(uiColor: .tertiarySystemBackground)
                                    ],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                )
                            )
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .stroke(
                                Color.secondary.opacity(0.25),
                                style: StrokeStyle(lineWidth: 1.5, dash: [6, 4])
                            )

                        VStack(spacing: 8) {
                            Image(systemName: "photo.badge.plus")
                                .font(.system(size: 32))
                                .foregroundStyle(.blue)
                            Text("Assign Card Skin")
                                .font(.subheadline.bold())
                            Text("Tap to choose photo")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .frame(width: width, height: height)
            .shadow(color: .black.opacity(0.12), radius: 6, y: 3)
            .contentShape(Rectangle())
            .onTapGesture { onPickImage() }
        }
        .aspectRatio(1.586, contentMode: .fit)
    }

    @ViewBuilder
    private func controlsRow(
        backupValidation: OriginalArtworkBackupValidation,
        recoveryCount: Int
    ) -> some View {
        HStack(spacing: 8) {
            Toggle("", isOn: Binding(
                get: { card.isSelected },
                set: { onToggleSelected($0) }
            ))
            .labelsHidden()

            HStack(spacing: 4) {
                Text(card.id.prefix(8) + "…" + card.id.suffix(6))
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)

                Button {
                    UIPasteboard.general.string = card.id
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                    copied = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                        copied = false
                    }
                } label: {
                    Image(systemName: copied ? "checkmark.circle.fill" : "doc.on.doc")
                        .font(.system(size: 10))
                        .foregroundStyle(copied ? .green : .secondary)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Color(uiColor: .systemFill))
            .clipShape(Capsule())

            Spacer()

            if backupValidation.isValid {
                Label("Verified", systemImage: "checkmark.shield.fill")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.green)
            }

            if recoveryCount > 0 {
                Image(systemName: "lifepreserver.fill")
                    .foregroundStyle(.orange)
                    .font(.system(size: 13))
            }

            Button(role: .destructive, action: onDelete) {
                Image(systemName: "trash")
                    .font(.system(size: 14))
                    .foregroundStyle(.secondary)
                    .frame(width: 32, height: 32)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 4)
    }
}

struct WalletRecoveryDiagnosticsView: View {
    @EnvironmentObject var vm: AppViewModel
    @Environment(\.dismiss) private var dismiss
    let cardId: String
    @State private var refreshToken = UUID()

    private var items: [WalletRecoveryItem] {
        _ = refreshToken
        return AppViewModel.walletRecoveryItems(for: cardId)
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    if items.isEmpty {
                        ContentUnavailableView(
                            "No Recovery Files",
                            systemImage: "checkmark.shield",
                            description: Text(
                                "There are no retained Wallet write-back or rollback snapshots for this card."
                            )
                        )
                    } else {
                        ForEach(items) { item in
                            VStack(alignment: .leading, spacing: 7) {
                                HStack {
                                    Label(item.kind.rawValue, systemImage: icon(for: item.kind))
                                        .font(.subheadline.bold())
                                    Spacer()
                                    Text("\(item.fileCount) file\(item.fileCount == 1 ? "" : "s")")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }

                                Text(item.url.lastPathComponent)
                                    .font(.caption.monospaced())
                                    .foregroundStyle(.secondary)
                                    .textSelection(.enabled)

                                if item.kind == .incompleteOriginal {
                                    Text(
                                        "Kept for diagnosis. AirCard will not overwrite or auto-restore " +
                                        "this incomplete original set."
                                    )
                                    .font(.caption2)
                                    .foregroundStyle(.orange)
                                } else {
                                    Button {
                                        vm.retryRecovery(item)
                                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                                            refreshToken = UUID()
                                        }
                                    } label: {
                                        Label("Retry Write-Back", systemImage: "arrow.uturn.backward")
                                    }
                                    .buttonStyle(.bordered)
                                    .controlSize(.small)
                                }
                            }
                            .padding(.vertical, 4)
                        }
                    }
                } header: {
                    Text("Retained recovery data")
                } footer: {
                    Text(
                        "Recovery files are retained only when AirCard cannot safely complete or " +
                        "roll back a move-based Wallet file operation."
                    )
                }
            }
            .navigationTitle("Recovery Diagnostics")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Refresh") { refreshToken = UUID() }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    private func icon(for kind: WalletRecoveryKind) -> String {
        switch kind {
        case .scanWriteBack: return "photo.badge.arrow.down"
        case .restoreSnapshot: return "arrow.uturn.backward.circle"
        case .incompleteOriginal: return "archivebox"
        }
    }
}
