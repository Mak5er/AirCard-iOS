import SwiftUI
import UIKit
import PhotosUI
import UniformTypeIdentifiers

/// Feature root used by the original-artwork branch.
/// Existing Pairing, Passcode and Wallpaper tabs are reused unchanged while the
/// Wallet tab is replaced by a backup-aware implementation.
struct AirCardFeatureRootView: View {
    @EnvironmentObject var vm: AppViewModel

    var body: some View {
        TabView(selection: $vm.selectedTab) {
            PairingTab()
                .tabItem { Label("Pairing", systemImage: "antenna.radiowaves.left.and.right") }
                .tag(AppTab.pairing)

            WalletCardsBackupTab()
                .tabItem { Label("Wallet Cards", systemImage: "creditcard.fill") }
                .tag(AppTab.walletCards)

            PasscodeThemeTab()
                .tabItem { Label("Passcode", systemImage: "lock.circle.fill") }
                .tag(AppTab.passcodeThemes)

            TendiesView()
                .tabItem { Label("Wallpapers", systemImage: "photo.stack.fill") }
                .tag(AppTab.wallpapers)
        }
        .alert("Notice", isPresented: Binding(
            get: { vm.errorMessage != nil },
            set: { if !$0 { vm.errorMessage = nil } }
        )) {
            Button("OK") { vm.errorMessage = nil }
        } message: {
            Text(vm.errorMessage ?? "")
        }
        .alert("Success! 🎉", isPresented: $vm.showSuccessAlert) {
            Button("OK") {}
        } message: {
            Text(vm.successAlertMessage)
        }
        .sheet(isPresented: $vm.showShareSheet) {
            if let url = vm.exportedThemeURL {
                ShareSheet(items: [url])
            }
        }
        .onAppear {
            vm.showSuccessAlert = false
            vm.successAlertMessage = ""
        }
    }
}

struct WalletCardsBackupTab: View {
    @EnvironmentObject var vm: AppViewModel

    @State private var newHashText = ""
    @State private var showAddSheet = false
    @State private var showCredits = false
    @State private var showSourceDialog = false
    @State private var isPhotosPickerPresented = false
    @State private var isDocumentPickerPresented = false
    @State private var selectedPhotos: [PhotosPickerItem] = []
    @State private var restoreCardId: String? = nil
    @State private var knownCardIds: Set<String> = []

    enum ActiveCardPicker: Identifiable {
        case singleCard(String)
        case bulkAll

        var id: String {
            switch self {
            case .singleCard(let id): return id
            case .bulkAll: return "bulk_all"
            }
        }
    }

    @State private var activePicker: ActiveCardPicker? = nil

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    scannerBanner

                    if vm.cards.isEmpty {
                        walletEmptyState
                            .padding(.top, 40)
                    } else {
                        cardsList
                    }
                }
                .padding(.vertical)
                .transaction { $0.animation = nil }
            }
            .transaction { $0.animation = nil }
            .safeAreaInset(edge: .bottom) {
                Color.clear.frame(height: 60)
            }
            .background(Color(uiColor: .systemGroupedBackground))
            .navigationTitle("Wallet Cards (\(vm.cards.count))")
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button {
                        vm.toggleCardScanning()
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: vm.isScanningCards ? "stop.circle.fill" : "wave.3.left.circle")
                            Text(vm.isScanningCards ? "Stop Scan" : "Scan Cards")
                        }
                        .font(.subheadline.bold())
                        .foregroundStyle(vm.isScanningCards ? .red : .blue)
                    }
                    .transaction { $0.animation = nil }
                }

                ToolbarItem(placement: .navigationBarTrailing) {
                    Menu {
                        Button {
                            showAddSheet = true
                        } label: {
                            Label("Add Card Manually", systemImage: "plus")
                        }

                        if !vm.cards.isEmpty {
                            Button {
                                activePicker = .bulkAll
                                showSourceDialog = true
                            } label: {
                                Label("Set Skin for All Cards...", systemImage: "photo.on.rectangle.angled")
                            }

                            Divider()

                            Button {
                                vm.selectAllCards(true)
                            } label: {
                                Label("Select All", systemImage: "checkmark.circle")
                            }

                            Button {
                                vm.selectAllCards(false)
                            } label: {
                                Label("Deselect All", systemImage: "circle")
                            }

                            Divider()

                            Button(role: .destructive) {
                                withAnimation(.spring(response: 0.32, dampingFraction: 0.82)) {
                                    AppViewModel.removeAllScannedCardPreviews()
                                    vm.clearAllCards()
                                }
                            } label: {
                                Label("Clear All Cards", systemImage: "trash")
                            }

                            Divider()

                            Button {
                                showCredits = true
                            } label: {
                                Label("Credits", systemImage: "heart.fill")
                            }
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                            .font(.title3)
                    }
                }

                ToolbarItem(placement: .navigationBarTrailing) {
                    flashButton
                }
            }
            .sheet(isPresented: $showCredits) {
                CreditsSheet()
            }
            .sheet(isPresented: $showAddSheet) {
                AddCardSheet(hashText: $newHashText) {
                    vm.addCardHash(newHashText)
                    newHashText = ""
                    showAddSheet = false
                }
            }
            .confirmationDialog(
                "Choose Image Source",
                isPresented: $showSourceDialog,
                titleVisibility: .visible
            ) {
                Button {
                    isPhotosPickerPresented = true
                } label: {
                    Label("Photo Library", systemImage: "photo.on.rectangle")
                }

                Button {
                    isDocumentPickerPresented = true
                } label: {
                    Label("Choose from Files…", systemImage: "folder")
                }

                Button("Cancel", role: .cancel) {
                    activePicker = nil
                }
            }
            .confirmationDialog(
                "Restore original card artwork?",
                isPresented: Binding(
                    get: { restoreCardId != nil },
                    set: { if !$0 { restoreCardId = nil } }
                ),
                titleVisibility: .visible
            ) {
                Button("Restore Original") {
                    guard let cardId = restoreCardId else { return }
                    restoreCardId = nil
                    vm.restoreOriginalArtworkExactly(for: cardId)
                }
                Button("Cancel", role: .cancel) {
                    restoreCardId = nil
                }
            } message: {
                Text("This restores the exact artwork saved before AirCard first modified this card. Your custom image remains saved in AirCard.")
            }
            .photosPicker(
                isPresented: $isPhotosPickerPresented,
                selection: $selectedPhotos,
                maxSelectionCount: 1,
                matching: .images
            )
            .onChange(of: selectedPhotos) { _, items in
                guard let item = items.first, let picker = activePicker else {
                    if items.isEmpty { activePicker = nil }
                    return
                }

                let currentPicker = picker
                Task {
                    if let image = await item.loadUIImage(maxDimension: 2560) {
                        await MainActor.run {
                            switch currentPicker {
                            case .singleCard(let cardId):
                                vm.setCardImage(for: cardId, image: image)
                            case .bulkAll:
                                vm.setSkinForAllCards(image: image)
                            }
                        }
                    }

                    await MainActor.run {
                        selectedPhotos = []
                        activePicker = nil
                    }
                }
            }
            .sheet(isPresented: $isDocumentPickerPresented) {
                DocumentPickerView(allowedContentTypes: [
                    .image, .png, .jpeg, .heic,
                    UTType(filenameExtension: "webp") ?? .image,
                    UTType(filenameExtension: "tiff") ?? .image
                ]) { url in
                    guard let picker = activePicker else { return }
                    if let data = try? Data(contentsOf: url),
                       let image = ImageEngine.safeImageFromData(data, maxDimension: 2560) {
                        switch picker {
                        case .singleCard(let cardId):
                            vm.setCardImage(for: cardId, image: image)
                        case .bulkAll:
                            vm.setSkinForAllCards(image: image)
                        }
                    }
                    activePicker = nil
                }
            }
            .onAppear {
                knownCardIds = Set(vm.cards.map(\.id))
            }
            .onChange(of: vm.cards.map(\.id)) { _, ids in
                let currentIds = Set(ids)
                let newlyAdded = currentIds.subtracting(knownCardIds)
                knownCardIds = currentIds

                guard vm.isScanningCards else { return }
                for cardId in newlyAdded {
                    vm.captureScannedCardPreviewIfNeeded(for: cardId)
                }
            }
        }
    }

    @ViewBuilder
    private var scannerBanner: some View {
        if vm.isScanningCards || !vm.scanStatusText.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    if vm.isScanningCards {
                        ProgressView().scaleEffect(0.85)
                        Text("Live Scanner Active")
                            .font(.subheadline.bold())
                            .foregroundStyle(.blue)
                    } else {
                        Image(systemName: "wave.3.left.circle")
                            .foregroundStyle(.secondary)
                        Text("Scanner Status")
                            .font(.subheadline.bold())
                            .foregroundStyle(.secondary)
                    }

                    Spacer()

                    if vm.isScanningCards {
                        Button("Stop") {
                            vm.stopCardScanning()
                        }
                        .font(.caption.bold())
                        .buttonStyle(.borderedProminent)
                        .tint(.red)
                        .controlSize(.small)
                    }
                }

                Text(vm.scanStatusText)
                    .font(.caption)
                    .foregroundStyle(
                        vm.scanStatusText.contains("stopped") || vm.scanStatusText.contains("error")
                            ? .orange
                            : .secondary
                    )
            }
            .padding(14)
            .background(
                vm.isScanningCards
                    ? Color.blue.opacity(0.12)
                    : Color(uiColor: .secondarySystemBackground)
            )
            .clipShape(RoundedRectangle(cornerRadius: 14))
            .padding(.horizontal)
            .transaction { $0.animation = nil }
        }
    }

    @ViewBuilder
    private var cardsList: some View {
        VStack(spacing: 16) {
            ForEach(vm.cards, id: \.id) { card in
                let cardIndex = vm.cards.firstIndex(where: { $0.id == card.id }) ?? 0
                let hasBackup = AppViewModel.hasOriginalArtworkBackup(for: card.id)

                VStack(spacing: 8) {
                    WalletCardPreviewView(
                        card: card,
                        cardIndex: cardIndex,
                        onToggleSelected: { isSelected in
                            vm.setCardSelected(id: card.id, selected: isSelected)
                        },
                        onPickImage: {
                            activePicker = .singleCard(card.id)
                            showSourceDialog = true
                        },
                        onClearImage: {
                            vm.clearCardImage(for: card.id)
                        },
                        onDelete: {
                            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                            AppViewModel.removeScannedCardPreview(for: card.id)
                            vm.deleteCard(id: card.id)
                        }
                    )

                    if hasBackup {
                        HStack(spacing: 10) {
                            Label("Original artwork saved", systemImage: "checkmark.circle.fill")
                                .font(.caption.bold())
                                .foregroundStyle(.green)

                            Spacer()

                            Button {
                                restoreCardId = card.id
                            } label: {
                                Label("Restore Original", systemImage: "arrow.uturn.backward")
                                    .font(.caption.bold())
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                            .disabled(vm.cardFlashPhase == .running)
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 9)
                        .background(Color(uiColor: .secondarySystemGroupedBackground))
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    }
                }
                .id(card.id)
            }

            if !vm.cardFlashLog.isEmpty {
                CompactLogView(
                    title: "Flash Log (\(vm.cardFlashLog.count) lines)",
                    lines: vm.cardFlashLog,
                    onClear: { vm.cardFlashLog.removeAll() }
                )
                .padding(.top, 8)
            }
        }
        .padding(.horizontal)
    }

    @ViewBuilder
    private var flashButton: some View {
        Button {
            vm.flashCardsPreservingOriginalArtwork()
        } label: {
            HStack(spacing: 6) {
                if case .running = vm.cardFlashPhase {
                    ProgressView()
                        .progressViewStyle(CircularProgressViewStyle(tint: .white))
                        .scaleEffect(0.75)
                    Text("Flashing…")
                        .font(.system(size: 13, weight: .semibold))
                } else if case .done(let ok) = vm.cardFlashPhase, !ok {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 12, weight: .semibold))
                    Text("Retry")
                        .font(.system(size: 13, weight: .semibold))
                } else {
                    Image(systemName: "bolt.fill")
                        .font(.system(size: 12, weight: .semibold))
                    Text("Flash")
                        .font(.system(size: 13, weight: .semibold))
                }
            }
            .padding(.horizontal, 4)
            .frame(minHeight: 28)
        }
        .buttonStyle(.borderedProminent)
        .tint({
            if case .done(let ok) = vm.cardFlashPhase, !ok {
                return Color.orange
            }
            return Color.blue
        }())
        .disabled(!vm.canFlashCards || vm.cardFlashPhase == .running)
        .animation(.easeInOut(duration: 0.2), value: vm.cardFlashPhase)
    }

    private var walletEmptyState: some View {
        VStack(spacing: 18) {
            Image(systemName: "creditcard.viewfinder")
                .font(.system(size: 56))
                .foregroundStyle(.blue.opacity(0.8))

            Text("No Cards Detected Yet")
                .font(.title3.bold())

            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .top, spacing: 10) {
                    Text("1.")
                        .bold()
                        .foregroundStyle(.blue)
                    Text("Tap **Scan Cards** in the toolbar above.")
                }

                HStack(alignment: .top, spacing: 10) {
                    Text("2.")
                        .bold()
                        .foregroundStyle(.blue)
                    Text("On this iPhone, **double-click the Side button**, authenticate with **Face ID**, and **tap your card**.")
                }

                HStack(alignment: .top, spacing: 10) {
                    Text("3.")
                        .bold()
                        .foregroundStyle(.blue)
                    Text("Your card will appear here automatically with its Wallet artwork when available.")
                }
            }
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .padding(16)
            .background(Color(uiColor: .secondarySystemGroupedBackground))
            .clipShape(RoundedRectangle(cornerRadius: 14))
            .padding(.horizontal, 24)

            HStack(spacing: 12) {
                Button {
                    vm.toggleCardScanning()
                } label: {
                    HStack(spacing: 6) {
                        Spacer()
                        Image(systemName: vm.isScanningCards ? "stop.circle.fill" : "wave.3.left.circle")
                        Text(vm.isScanningCards ? "Stop Scan" : "Scan Cards")
                        Spacer()
                    }
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .frame(height: 48)
                }
                .buttonStyle(.borderedProminent)
                .tint(vm.isScanningCards ? .red : .blue)

                Button {
                    showAddSheet = true
                } label: {
                    HStack(spacing: 6) {
                        Spacer()
                        Image(systemName: "plus")
                        Text("Add Manually")
                        Spacer()
                    }
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .frame(height: 48)
                }
                .buttonStyle(.bordered)
            }
            .padding(.horizontal, 24)
        }
        .frame(maxWidth: .infinity)
    }
}
