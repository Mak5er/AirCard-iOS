//
//  TendiesView.swift
//  AirCard-iOS
//
//  Dedicated UI for importing, previewing, and flashing PosterBoard .tendies wallpapers.
//  Unified Form design matching Passcode Theme and Wallet Cards tabs.
//

import SwiftUI
import UniformTypeIdentifiers

struct TendiesView: View {
    @EnvironmentObject var vm: AppViewModel
    @State private var showFilePicker = false
    @State private var selectedDetailItem: TendieItem? = nil
    @State private var isNeoSpringing = false
    @State private var removalCandidate: TemplateInstallation?
    @State private var libraryDeletionCandidate: TendieItem?

    private var selectedCount: Int {
        vm.tendieItems.filter { $0.isSelected }.count
    }

    private var selectedAll: Bool {
        !vm.tendieItems.isEmpty && vm.tendieItems.allSatisfy { $0.isSelected }
    }

    var body: some View {
        NavigationStack {
            Form {
                // Notice Banners
                if let err = vm.errorMessage {
                    Section {
                        HStack(spacing: 8) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundColor(.red)
                            Text(err)
                                .font(.caption)
                                .foregroundColor(.red)
                            Spacer()
                            Button {
                                vm.errorMessage = nil
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .foregroundColor(.secondary)
                            }
                        }
                    }
                }

                // Section 1: Import Wallpapers
                Section {
                    Button {
                        showFilePicker = true
                    } label: {
                        HStack(spacing: 8) {
                            Spacer()
                            Image(systemName: "doc.badge.plus")
                            Text(vm.tendieItems.isEmpty ? "Choose .tendies from Files…" : "Import More Wallpapers…")
                            Spacer()
                        }
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .frame(height: 48)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.blue)
                    .disabled(vm.isDeviceOperationInProgress)
                }

                Section("Connected Device") {
                    if let device = vm.templateDevice {
                        Text(device.name.isEmpty ? device.model : device.name).font(.headline)
                        Text("\(device.model) · \(device.udid)").font(.caption).textSelection(.enabled)
                    } else {
                        Text("Connect LocalDevVPN and refresh to identify the target.").font(.caption)
                    }
                    Button {
                        Task { await vm.checkInstalledTemplates() }
                    } label: {
                        Label(
                            vm.isCheckingTemplates ? "Checking…" : "Refresh Device & Templates",
                            systemImage: "arrow.clockwise")
                    }
                    .disabled(vm.isDeviceOperationInProgress)
                }

                installedTemplatesSection

                // Section 3: Wallpapers Gallery
                if !vm.tendieItems.isEmpty {
                    Section {
                        HStack {
                            Text("\(vm.tendieItems.count) Wallpapers Imported")
                                .font(.caption.bold())
                                .foregroundColor(.secondary)
                            Spacer()
                            Button(selectedAll ? "Deselect All" : "Select All") {
                                let target = !selectedAll
                                for i in 0..<vm.tendieItems.count {
                                    vm.tendieItems[i].isSelected = target
                                }
                            }
                            .font(.caption)
                            .disabled(vm.isDeviceOperationInProgress)
                        }

                        ForEach($vm.tendieItems) { $item in
                            TendieRowView(item: $item) {
                                selectedDetailItem = item
                            } onDelete: {
                                libraryDeletionCandidate = item
                            }
                            .disabled(vm.isDeviceOperationInProgress)
                        }
                    } header: {
                        Text("Imported Files")
                    }
                } else {
                    Section {
                        VStack(spacing: 10) {
                            Image(systemName: "photo.stack")
                                .font(.system(size: 32))
                                .foregroundColor(.secondary)
                            Text("No .tendies wallpapers loaded yet")
                                .font(.subheadline)
                                .foregroundColor(.secondary)
                            Text("Tap 'Choose .tendies from Files' or copy wallpapers into On My iPhone › AirCard-iOS.")
                                .font(.caption)
                                .foregroundColor(.secondary)
                                .multilineTextAlignment(.center)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                    }
                }

                // Section 4: Flash Action & Respring
                Section {
                    VStack(spacing: 12) {
                        if case .running = vm.tendiesFlashPhase {
                            HStack(spacing: 10) {
                                ProgressView()
                                VStack(alignment: .leading, spacing: 4) {
                                    Text("Updating Wallpapers…").font(.subheadline.bold())
                                    ProgressView(value: vm.tendiesFlashProgress)
                                }
                            }
                            .padding(.vertical, 4)
                        } else {
                            Button {
                                Task {
                                    await vm.flashSelectedTendies()
                                }
                            } label: {
                                HStack(spacing: 8) {
                                    Spacer()
                                    Image(systemName: "sparkles")
                                    Text("Flash \(selectedCount) Wallpaper\(selectedCount == 1 ? "" : "s")")
                                    Spacer()
                                }
                                .font(.headline)
                                .frame(maxWidth: .infinity)
                                .frame(height: 48)
                            }
                            .buttonStyle(.borderedProminent)
                            .tint(.blue)
                            .disabled(
                                selectedCount == 0 || vm.isDeviceOperationInProgress || vm.templateJournalError != nil)
                        }

                        Button(role: .destructive) {
                            vm.isNeoSpringing = true
                            isNeoSpringing = true
                            RespringHelper.triggerNeoSpring()
                        } label: {
                            HStack(spacing: 8) {
                                Spacer()
                                Image(systemName: "bolt.fill")
                                Text("Respring (NeoSpring)")
                                Spacer()
                            }
                            .font(.headline)
                            .frame(maxWidth: .infinity)
                            .frame(height: 48)
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(.red)
                        .disabled(vm.isDeviceOperationInProgress)
                    }
                    .listRowInsets(EdgeInsets(top: 12, leading: 14, bottom: 12, trailing: 14))
                } footer: {
                    Text(
                        "Installing or removing templates always runs AirCard’s cache refresh and NeoSpring. Existing lock-screen wallpapers are kept. Removal order does not matter."
                    )
                }

                // Section 5: Flash Log (CompactLogView)
                if !vm.tendiesFlashLog.isEmpty {
                    Section {
                        CompactLogView(
                            title: "Flash Log (\(vm.tendiesFlashLog.count) lines)",
                            lines: vm.tendiesFlashLog,
                            onClear: { vm.tendiesFlashLog.removeAll() }
                        )
                    }
                }
            }
            .safeAreaInset(edge: .bottom) {
                Color.clear.frame(height: 60)
            }
            .navigationTitle("Wallpapers")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button {
                        showFilePicker = true
                    } label: {
                        Image(systemName: "plus")
                            .font(.headline)
                    }
                    .disabled(vm.isDeviceOperationInProgress)
                }
            }
            .sheet(isPresented: $showFilePicker) {
                TendiesDocumentPickerView { urls in
                    Task {
                        await vm.importTendieFiles(urls: urls)
                    }
                }
            }
            .sheet(item: $selectedDetailItem) { item in
                TendieDetailSheet(item: item)
            }
            .confirmationDialog(
                "Remove this installed template?",
                isPresented: Binding(
                    get: { removalCandidate != nil }, set: { if !$0 { removalCandidate = nil } }
                ), titleVisibility: .visible
            ) {
                if let record = removalCandidate {
                    Button("Remove Template & Respring", role: .destructive) {
                        Task { await vm.removeInstalledTemplate(record) }
                    }
                }
            } message: {
                Text(
                    "The imported template will disappear from Add New Wallpaper. Wallpapers already created from it are kept. AirCard will refresh and respring automatically."
                )
            }
            .confirmationDialog(
                "Delete imported file?",
                isPresented: Binding(
                    get: { libraryDeletionCandidate != nil }, set: { if !$0 { libraryDeletionCandidate = nil } }
                ), titleVisibility: .visible
            ) {
                if let item = libraryDeletionCandidate {
                    Button("Delete Local .tendies File", role: .destructive) { vm.deleteTendie(item: item) }
                }
            } message: {
                Text(
                    "This deletes the archive from AirCard. Use Installed Templates to remove a template from the system gallery."
                )
            }
            .onAppear {
                vm.isNeoSpringing = false
                isNeoSpringing = false
                vm.showSuccessAlert = false
                vm.successAlertMessage = ""
                vm.scanDocumentsForTendies()
                vm.reloadTemplateInstallations()
            }
            .task {
                if vm.hasPairingFile { await vm.checkInstalledTemplates() }
            }
            .overlay {
                if isNeoSpringing || vm.isNeoSpringing {
                    ZStack {
                        Color.black.ignoresSafeArea()
                        NeoSpringView()
                            .brightness(-1.0)
                            .ignoresSafeArea()
                    }
                }
            }
        }
    }

    private var installedTemplatesSection: some View {
        Section {
            if let error = vm.templateJournalError {
                Text(error).font(.caption).foregroundStyle(.red)
            }
            let records = vm.templateInstallations.filter { $0.phase != .removed }
            if records.isEmpty {
                Text("No templates recorded by this version.").foregroundStyle(.secondary)
            }
            ForEach(records) { record in
                VStack(alignment: .leading, spacing: 6) {
                    Text(record.name).font(.headline)
                    Text("\(record.deviceName) · \(record.ownership.udid)").font(.caption2)
                    Text(templateStatus(record)).font(.caption).foregroundStyle(.secondary)
                    if let error = record.lastError { Text(error).font(.caption).foregroundStyle(.orange) }
                    if record.ownership.udid == vm.templateDevice?.udid
                        && record.ownership.container == vm.templateDevice?.container
                    {
                        HStack {
                            Button("Remove Template", role: .destructive) { removalCandidate = record }
                            if record.phase != .installed {
                                Button(record.action == .remove ? "Continue Removal" : "Retry Refresh") {
                                    Task { await vm.finishTemplateRefresh(record) }
                                }
                            }
                        }
                        .buttonStyle(.borderless)
                        .disabled(vm.isDeviceOperationInProgress || vm.templateJournalError != nil)
                    } else {
                        Text("Refresh the matching device to manage this record.").font(.caption2)
                    }
                }
                .padding(.vertical, 4)
            }
        } header: {
            Text("Installed Templates")
        } footer: {
            Text(
                "Only templates installed with tracking can be removed here. Keep AirCard installed to retain its removal records."
            )
        }
    }

    private func templateStatus(_ record: TemplateInstallation) -> String {
        switch record.phase {
        case .installed: return "Template written · Choose it in Wallpaper settings"
        case .installing: return "Installation interrupted · Check or remove"
        case .removing: return "Removal interrupted · Continue removal"
        case .refreshPending: return "Refresh pending"
        case .needsAttention: return "Needs attention · Record preserved"
        case .removed: return "Removed"
        }
    }

}

// MARK: - Tendie Row View

struct TendieRowView: View {
    @Binding var item: TendieItem
    let onInspect: () -> Void
    let onDelete: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Toggle("", isOn: $item.isSelected)
                .labelsHidden()

            if let imgData = item.previewImageData, let uiImg = UIImage(data: imgData) {
                Image(uiImage: uiImg)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: 44, height: 60)
                    .cornerRadius(6)
                    .clipped()
            } else {
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color(UIColor.tertiarySystemFill))
                    .frame(width: 44, height: 60)
                    .overlay {
                        Image(systemName: item.posterType.systemIcon)
                            .foregroundColor(.secondary)
                    }
            }

            VStack(alignment: .leading, spacing: 3) {
                Text(item.name)
                    .font(.subheadline.bold())
                    .lineLimit(1)

                HStack(spacing: 6) {
                    Text(item.posterType.rawValue)
                        .font(.caption2.bold())
                        .foregroundColor(item.posterType.badgeColor)

                    Text("•")
                        .font(.caption2)
                        .foregroundColor(.secondary)

                    Text("\(item.descriptorCount) item\(item.descriptorCount == 1 ? "" : "s")")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
            }

            Spacer()

            Button {
                onInspect()
            } label: {
                Image(systemName: "info.circle")
                    .foregroundColor(.blue)
                    .frame(width: 32, height: 32)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)

            Button(role: .destructive) {
                onDelete()
            } label: {
                Image(systemName: "trash")
                    .foregroundColor(.red)
                    .frame(width: 32, height: 32)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
        }
        .padding(.vertical, 4)
    }
}

// MARK: - Tendie Detail Sheet

struct TendieDetailSheet: View {
    let item: TendieItem
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section {
                    if let imgData = item.previewImageData, let uiImg = UIImage(data: imgData) {
                        Image(uiImage: uiImg)
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .frame(maxWidth: .infinity, maxHeight: 300)
                            .cornerRadius(12)
                            .listRowInsets(EdgeInsets(top: 12, leading: 12, bottom: 12, trailing: 12))
                            .listRowBackground(Color.clear)
                    }
                }

                Section("Information") {
                    detailRow(title: "Name", value: item.name)
                    detailRow(title: "File Name", value: item.fileName)
                    detailRow(title: "Type", value: item.posterType.rawValue)
                    detailRow(title: "Descriptors", value: "\(item.descriptorCount)")
                    detailRow(title: "Target Extension", value: item.posterType.extensionBundleId)
                    detailRow(title: "Format", value: item.isContainer ? "App Container" : "Descriptor Archive")
                    if item.unsafeContainer {
                        detailRow(title: "Warning", value: "Contains SQLite database")
                    }
                }
            }
            .navigationTitle(item.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Done") {
                        dismiss()
                    }
                }
            }
        }
    }

    private func detailRow(title: String, value: String) -> some View {
        HStack {
            Text(title)
                .font(.subheadline)
                .foregroundColor(.secondary)
            Spacer()
            Text(value)
                .font(.subheadline.bold())
                .foregroundColor(.primary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
    }
}

// MARK: - Tendies Document Picker

struct TendiesDocumentPickerView: UIViewControllerRepresentable {
    let onPick: ([URL]) -> Void
    @Environment(\.dismiss) private var dismiss

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        var contentTypes: [UTType] = []
        if let customType = UTType("com.aircard.tendies") {
            contentTypes.append(customType)
        }
        if let extType = UTType(filenameExtension: "tendies") {
            contentTypes.append(extType)
        }
        contentTypes.append(contentsOf: [.archive, .zip, .data, .item])

        // asCopy: true ensures iOS safely copies documents into app sandbox tmp directory
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: contentTypes, asCopy: true)
        picker.delegate = context.coordinator
        picker.allowsMultipleSelection = true
        return picker
    }

    func updateUIViewController(_ uiViewController: UIDocumentPickerViewController, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    final class Coordinator: NSObject, UIDocumentPickerDelegate {
        let parent: TendiesDocumentPickerView

        init(_ parent: TendiesDocumentPickerView) {
            self.parent = parent
        }

        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            guard !urls.isEmpty else { return }
            parent.onPick(urls)
            parent.dismiss()
        }

        func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
            parent.dismiss()
        }
    }
}
