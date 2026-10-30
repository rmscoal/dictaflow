import SwiftUI

/// Compact Transcription entry point: enabled terms as tags, active count,
/// and a button opening the unified manager sheet.
struct CustomVocabularyEditor: View {
    @ObservedObject var appState: DictaFlowAppState
    @State private var showsManager = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Help DictaFlow recognize your words and correct recurring spellings.")
                .font(.system(size: 11))
                .foregroundStyle(AppTheme.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
            let enabled = appState.vocabularySettings.entries.filter(\.isEnabled)
            if !enabled.isEmpty {
                KeywordTagLayout {
                    ForEach(enabled.prefix(8)) { entry in
                        Text(entry.text)
                            .font(.system(size: 11))
                            .lineLimit(1)
                            .padding(.horizontal, 9)
                            .padding(.vertical, 4)
                            .background(AppTheme.controlFill, in: Capsule())
                    }
                    if enabled.count > 8 {
                        Text("+\(enabled.count - 8) more")
                            .font(.system(size: 11))
                            .foregroundStyle(AppTheme.secondaryText)
                            .padding(.horizontal, 9)
                            .padding(.vertical, 4)
                    }
                }
            }
            HStack {
                Text("\(enabled.count) active \(enabled.count == 1 ? "entry" : "entries")")
                    .font(.system(size: 11))
                    .foregroundStyle(AppTheme.secondaryText)
                Spacer()
                Button("Manage vocabulary…") { showsManager = true }
                    .buttonStyle(EmberButtonStyle())
                    .disabled(appState.whisperSettingsLocked)
            }
        }
        .sheet(isPresented: $showsManager) {
            VocabularyManagerView(appState: appState)
        }
    }
}

struct VocabularyManagerView: View {
    @ObservedObject var appState: DictaFlowAppState
    @Environment(\.dismiss) private var dismiss
    @State private var searchText = ""
    @State private var editingEntry: VocabularyEntry?
    @State private var showsAdd = false

    private var filtered: [VocabularyEntry] {
        let query = VocabularySettings.normalizedKey(searchText)
        guard !query.isEmpty else { return appState.vocabularySettings.entries }
        return appState.vocabularySettings.entries.filter { entry in
            VocabularySettings.normalizedKey(entry.text).contains(query)
                || entry.replacementSpellings.contains { VocabularySettings.normalizedKey($0).contains(query) }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Vocabulary")
                    .font(.system(size: 17, weight: .medium))
                Spacer()
                Button("Done") { dismiss() }
                    .buttonStyle(EmberButtonStyle())
                    .keyboardShortcut(.cancelAction)
            }
            Text("Save the correct word or phrase. Optionally add spellings you want replaced.")
                .font(.system(size: 12))
                .foregroundStyle(AppTheme.secondaryText)
            HStack(spacing: 8) {
                TextField("Search", text: $searchText)
                    .textFieldStyle(.roundedBorder)
                Button("Add word or phrase") { showsAdd = true }
                    .buttonStyle(EmberButtonStyle(primary: true))
                    .disabled(appState.whisperSettingsLocked || appState.vocabularySettings.entries.count >= VocabularySettings.maxEntries)
            }
            if filtered.isEmpty {
                Text(appState.vocabularySettings.entries.isEmpty ? "No vocabulary yet. Add a word or phrase." : "No matching entries.")
                    .font(.system(size: 12))
                    .foregroundStyle(AppTheme.secondaryText)
                    .padding(.vertical, 16)
            } else {
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(filtered) { entry in
                            VocabularyRow(appState: appState, entry: entry) { editingEntry = entry }
                            if entry.id != filtered.last?.id { EmberDivider() }
                        }
                    }
                }
            }
            let enabledCount = appState.vocabularySettings.entries.filter(\.isEnabled).count
            Text("\(enabledCount) active · \(appState.vocabularySettings.entries.count) total")
                .font(.system(size: 11))
                .foregroundStyle(AppTheme.secondaryText)
            Spacer(minLength: 0)
        }
        .padding(20)
        .frame(minWidth: 480, minHeight: 420)
        .foregroundStyle(AppTheme.primaryText)
        .background(AppTheme.tileFill)
        .sheet(isPresented: $showsAdd) {
            VocabularyEntryEditorView(appState: appState, entryID: nil, initialTerm: "", initialSpellings: [], isFromHistory: false)
        }
        .sheet(item: $editingEntry) { entry in
            VocabularyEntryEditorView(appState: appState, entryID: entry.id, initialTerm: entry.text, initialSpellings: entry.replacementSpellings, isFromHistory: false)
        }
    }
}

private struct VocabularyRow: View {
    @ObservedObject var appState: DictaFlowAppState
    let entry: VocabularyEntry
    let onEdit: () -> Void

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 10) { rowContent }
            VStack(alignment: .leading, spacing: 8) { rowContent }
        }
        .padding(.vertical, 10)
    }

    @ViewBuilder private var rowContent: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(entry.text)
                .font(.system(size: 13))
                .foregroundStyle(entry.isEnabled ? AppTheme.primaryText : AppTheme.secondaryText)
            Text(entry.replacementSpellings.isEmpty ? "Recognition hint only" : "Also replaces: \(entry.replacementSpellings.joined(separator: " · "))")
                .font(.system(size: 11))
                .foregroundStyle(AppTheme.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        HStack(spacing: 6) {
            Text(entry.isEnabled ? "Active" : "Inactive")
                .font(.system(size: 11))
                .foregroundStyle(AppTheme.secondaryText)
            Toggle("Enable \(entry.text)", isOn: Binding(
                get: { entry.isEnabled },
                set: { appState.setVocabularyEntryEnabled(id: entry.id, isEnabled: $0) }
            ))
            .toggleStyle(.switch)
            .controlSize(.mini)
            .labelsHidden()
            .disabled(appState.whisperSettingsLocked)
            .accessibilityLabel("Enable \(entry.text)")
            .accessibilityValue(entry.isEnabled ? "Active" : "Inactive")
        }
        Button("Edit", action: onEdit)
            .buttonStyle(EmberButtonStyle())
            .disabled(appState.whisperSettingsLocked)
    }
}

private struct SpellingRow: Identifiable {
    let id = UUID()
    var text: String
}

/// Shared editor for Add, Edit, and History correction.
struct VocabularyEntryEditorView: View {
    @ObservedObject var appState: DictaFlowAppState
    @Environment(\.dismiss) private var dismiss
    @State private var editingID: UUID?
    @State private var term: String
    @State private var spellings: [SpellingRow]
    @State private var errorMessage: String?
    @State private var conflictOwner: VocabularyEntry?
    let isFromHistory: Bool

    @FocusState private var focusedSpelling: UUID?

    init(appState: DictaFlowAppState, entryID: UUID?, initialTerm: String, initialSpellings: [String], isFromHistory: Bool) {
        self.appState = appState
        self.isFromHistory = isFromHistory
        _editingID = State(initialValue: entryID)
        _term = State(initialValue: initialTerm)
        _spellings = State(initialValue: initialSpellings.map { SpellingRow(text: $0) })
    }

    private var spellingTexts: [String] {
        spellings.map(\.text)
    }

    private var existingEntry: VocabularyEntry? {
        appState.vocabularySettings.entry(matchingTerm: term)
    }

    private var mergeNotice: String? {
        guard isFromHistory, let existing = existingEntry, editingID == nil else { return nil }
        let cleaned = spellingTexts.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        guard !cleaned.isEmpty else { return nil }
        if !cleaned.isEmpty, cleaned.allSatisfy({ candidate in existing.replacementSpellings.contains { VocabularySettings.normalizedKey($0) == VocabularySettings.normalizedKey(candidate) } }) {
            return "This correction is already saved in your vocabulary."
        }
        var notice = "This word is already in your vocabulary. Saving adds this spelling to \(existing.text)."
        if !existing.isEnabled { notice += " This entry is inactive and will stay inactive." }
        return notice
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(isFromHistory ? "Save correction" : (editingID == nil ? "Add word or phrase" : "Edit vocabulary"))
                .font(.system(size: 17, weight: .medium))
                .padding(.bottom, 14)
            ScrollView {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Word or phrase")
                        .font(.system(size: 12, weight: .semibold))
                    TextField("e.g. DictaFlow", text: $term)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit(save)
                    Text("The correct spelling. Helps recognition, but does not guarantee a match.")
                        .font(.system(size: 11))
                        .foregroundStyle(AppTheme.secondaryText)
                    Text("Also replace these spellings (optional)")
                        .font(.system(size: 12, weight: .semibold))
                        .padding(.top, 12)
                    ForEach($spellings) { $row in
                        HStack(spacing: 8) {
                            TextField("e.g. dicta flow", text: $row.text)
                                .textFieldStyle(.roundedBorder)
                                .focused($focusedSpelling, equals: row.id)
                            Button("Remove") {
                                spellings.removeAll { $0.id == row.id }
                            }
                            .buttonStyle(EmberButtonStyle())
                        }
                    }
                    Button("Add spelling") {
                        let row = SpellingRow(text: "")
                        spellings.append(row)
                        focusedSpelling = row.id
                    }
                    .buttonStyle(EmberButtonStyle())
                    .padding(.top, 4)
                    Text("When the transcript contains one of these spellings, replace it with your word or phrase after Refinement and Final formatting.")
                        .font(.system(size: 11))
                        .foregroundStyle(AppTheme.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                    if let mergeNotice {
                        Text(mergeNotice)
                            .font(.system(size: 12))
                            .padding(10)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(AppTheme.controlFill, in: RoundedRectangle(cornerRadius: 8))
                    }
                    if isFromHistory {
                        Text("Updates vocabulary for future dictations. This recording stays unchanged.")
                            .font(.system(size: 11))
                            .foregroundStyle(AppTheme.secondaryText)
                    }
                    if let errorMessage {
                        Text(errorMessage)
                            .font(.system(size: 12))
                            .foregroundStyle(AppTheme.errorText)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if let conflictOwner {
                        Button("Edit the entry for \(conflictOwner.text)") {
                            let merged = appState.vocabularySettings.mergingUnclaimedSpellings(spellingTexts, into: conflictOwner)
                            editingID = conflictOwner.id
                            term = conflictOwner.text
                            spellings = merged.map { SpellingRow(text: $0) }
                            self.conflictOwner = nil
                            errorMessage = nil
                        }
                        .buttonStyle(EmberButtonStyle())
                    }
                }
                .onChange(of: term) { conflictOwner = nil; errorMessage = nil }
                .onChange(of: spellingTexts) { conflictOwner = nil; errorMessage = nil }
                // Inset the fields so their focus rings are not clipped by
                // the scroll view; the matching negative margin below keeps
                // the fields aligned with the title and buttons.
                .padding(.horizontal, 4)
                .padding(.bottom, 8)
            }
            .padding(.horizontal, -4)
            HStack(spacing: 8) {
                if let editingID {
                    Button(role: .destructive) {
                        appState.deleteVocabularyEntry(id: editingID)
                        dismiss()
                    } label: {
                        Label("Delete", systemImage: "trash")
                            .foregroundStyle(AppTheme.destructive)
                    }
                    .buttonStyle(EmberButtonStyle())
                    .disabled(appState.whisperSettingsLocked)
                }
                Spacer()
                Button("Cancel") { dismiss() }
                    .buttonStyle(EmberButtonStyle())
                    .keyboardShortcut(.cancelAction)
                Button("Save", action: save)
                    .buttonStyle(EmberButtonStyle(primary: true))
                    .keyboardShortcut(.defaultAction)
                    .disabled(appState.whisperSettingsLocked)
            }
            .padding(.top, 16)
        }
        .padding(20)
        .frame(minWidth: 440, minHeight: 380)
        .foregroundStyle(AppTheme.primaryText)
        .background(AppTheme.tileFill)
    }

    private func save() {
        conflictOwner = nil
        if let error = appState.saveVocabularyEntry(id: editingID, text: term, spellings: spellingTexts, isFromHistory: isFromHistory) {
            errorMessage = error.message
            if case .spellingConflict(_, let owner) = error { conflictOwner = owner }
            if case .duplicateTerm(let existing) = error, !(isFromHistory && editingID == nil) { conflictOwner = existing }
            return
        }
        dismiss()
    }
}

private struct KeywordTagLayout: Layout {
    var horizontalSpacing: CGFloat = 6
    var verticalSpacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard !subviews.isEmpty else { return .zero }
        let maxWidth = proposal.width ?? .infinity
        var rowWidth: CGFloat = 0
        var totalHeight: CGFloat = 0
        var rowHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if rowWidth > 0 && rowWidth + size.width > maxWidth {
                totalHeight += rowHeight + verticalSpacing
                rowWidth = 0
                rowHeight = 0
            }
            rowHeight = max(rowHeight, size.height)
            rowWidth += size.width + horizontalSpacing
        }
        return CGSize(width: maxWidth.isFinite ? maxWidth : rowWidth, height: totalHeight + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX
        var y = bounds.minY
        var rowHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > bounds.minX && x + size.width > bounds.maxX {
                x = bounds.minX
                y += rowHeight + verticalSpacing
                rowHeight = 0
            }
            subview.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            rowHeight = max(rowHeight, size.height)
            x += size.width + horizontalSpacing
        }
    }
}
