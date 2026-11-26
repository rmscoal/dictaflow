import SwiftUI

struct LegacyDataItem: Identifiable, Equatable {
    let url: URL
    let displayName: String
    let byteCount: Int64
    let modified: Date?

    var id: URL { url }

    static func make(from url: URL) -> LegacyDataItem {
        LegacyDataItem(url: url, displayName: displayName(for: url),
                       byteCount: totalByteCount(under: url),
                       modified: modificationDate(of: url))
    }

    static func displayName(for url: URL) -> String {
        if url.lastPathComponent == "Previous attempt" { return "Previous attempt" }
        if url.lastPathComponent == "Liquid" { return "Models/Liquid" }
        return url.lastPathComponent
    }

    static func totalByteCount(under url: URL) -> Int64 {
        let files = FileManager.default
        guard let attributes = try? files.attributesOfItem(atPath: url.path) else { return 0 }
        if (attributes[.type] as? FileAttributeType) != .typeDirectory {
            return (attributes[.size] as? NSNumber)?.int64Value ?? 0
        }
        guard let enumerator = files.enumerator(at: url, includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey]) else { return 0 }
        var total: Int64 = 0
        for case let item as URL in enumerator {
            guard let values = try? item.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey]),
                  values.isRegularFile == true else { continue }
            total += Int64(values.fileSize ?? 0)
        }
        return total
    }

    static func modificationDate(of url: URL) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
    }
}

struct LegacyDataView: View {
    @ObservedObject var appState: DictaFlowAppState

    @State private var items: [LegacyDataItem] = []
    @State private var confirmsRemoval = false
    @State private var statusMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            EmberModuleHeading(title: "Previous DictaFlow data")
            Text("Omdo was previously DictaFlow. During the migration, Omdo copied DictaFlow's data and kept the original data, so you can check it before removing it. Removing it does not affect Omdo.")
                .font(.system(size: 12))
                .foregroundStyle(AppTheme.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.bottom, 18)
            EmberSectionHeading(title: "Stored in the previous location")
            EmberPanel {
                ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                    if index > 0 { EmberDivider() }
                    EmberRow(title: item.displayName, detail: detail(for: item)) {
                        Button {
                            NSWorkspace.shared.activateFileViewerSelecting([item.url])
                        } label: {
                            Label("Show in Finder", systemImage: "folder")
                        }
                        .buttonStyle(EmberButtonStyle())
                    }
                }
                if !items.isEmpty { EmberDivider() }
                VStack(alignment: .leading, spacing: 12) {
                    if let statusMessage {
                        Text(statusMessage)
                            .font(.system(size: 12))
                            .foregroundStyle(AppTheme.secondaryText)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    HStack(spacing: 10) {
                        Button {
                            NSWorkspace.shared.activateFileViewerSelecting(appState.legacyDataLocations)
                        } label: {
                            Label("Show in Finder", systemImage: "folder")
                        }
                        .buttonStyle(EmberButtonStyle())
                        .disabled(appState.legacyDataLocations.isEmpty)
                        Button("Remove previous data…") { confirmsRemoval = true }
                            .buttonStyle(EmberButtonStyle())
                            .disabled(appState.legacyDataLocations.isEmpty)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(20)
            }
        }
        .onAppear { reload() }
        .onChange(of: appState.legacyDataLocations) { reload() }
        .alert("Remove previous DictaFlow data?", isPresented: $confirmsRemoval) {
            Button("Cancel", role: .cancel) {}
            Button("Remove", role: .destructive) { remove() }
        } message: {
            Text("This permanently deletes the previous data listed here. Omdo keeps using its copied data. This cannot be undone.")
        }
    }

    private func detail(for item: LegacyDataItem) -> String {
        var parts = [appState.formattedLocalModelSize(item.byteCount)]
        if let modified = item.modified {
            parts.append("Modified \(modified.formatted(date: .abbreviated, time: .shortened))")
        }
        parts.append(item.url.path)
        return parts.joined(separator: " · ")
    }

    private func reload() {
        items = appState.legacyDataLocations.map(LegacyDataItem.make(from:))
    }

    private func remove() {
        if let error = appState.removeLegacyData() {
            statusMessage = error
        } else {
            statusMessage = nil
        }
        reload()
    }
}
