import AppKit
import SwiftUI
import UniformTypeIdentifiers

extension MeetingItem.Status {
    var title: String {
        switch self {
        case .open: "Open"
        case .inProgress: "In progress"
        case .done: "Done"
        case .dropped: "Dropped"
        }
    }
}

/// The "Actions" tab of a meeting: link to a series, review proposals, see the series' list.
struct MeetingActionsPane: View {
    let record: AudioTranscriptionRecord
    @ObservedObject var library: AudioCaptureLibrary
    @ObservedObject var store: MeetingActionStore
    @State private var newSeriesName = ""
    @State private var asksForSeriesName = false

    private var linked: MeetingSeries? { store.seriesContaining(recordID: record.id) }
    private var pending: [MeetingProposal] { store.proposals(for: record.id).filter { $0.decision == .pending } }
    private var suggestion: MeetingSeries? {
        guard linked == nil else { return nil }
        return store.suggestedSeries(for: record, speakerNames: Array((record.diarization?.speakerNames ?? [:]).values))
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                seriesBar
                if store.extractingRecordIDs.contains(record.id) {
                    ProgressView("Looking for actions and decisions…").controlSize(.small)
                }
                if !pending.isEmpty { proposalList }
                if let linked {
                    Text(linked.name).font(.headline)
                    MeetingItemsTable(seriesID: linked.id, store: store, minHeight: 220)
                } else if pending.isEmpty && !store.extractingRecordIDs.contains(record.id) {
                    Text("No action list yet. Link this meeting to a series, or find actions to start a new list.")
                        .foregroundStyle(.secondary)
                }
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .alert("New action list", isPresented: $asksForSeriesName) {
            TextField("Name, e.g. Weekly team meeting", text: $newSeriesName)
            Button("Create") {
                let created = store.createSeries(named: newSeriesName.isEmpty ? record.displayTitle : newSeriesName,
                                                 applicationName: record.applicationName)
                store.link(recordID: record.id, to: created.id)
                newSeriesName = ""
            }
            Button("Cancel", role: .cancel) {}
        }
    }

    private var seriesBar: some View {
        HStack(spacing: 8) {
            if let suggestion {
                Text("Same series as “\(suggestion.name)”?").font(.callout)
                Button("Link") { link(suggestion.id) }.buttonStyle(.borderedProminent).controlSize(.small)
            }
            Menu(linked == nil ? "Link to action list" : "Action list: \(linked?.name ?? "")") {
                ForEach(store.series) { series in
                    Button(series.name) { link(series.id) }
                }
                Divider()
                Button("New action list…") { newSeriesName = record.displayTitle; asksForSeriesName = true }
            }
            .fixedSize()
            Spacer()
            Button {
                library.extractActions(for: record)
            } label: {
                Label(linked == nil ? "Find actions" : "Check against list", systemImage: "checklist")
            }
            .disabled(store.extractingRecordIDs.contains(record.id) || record.transcript.isEmpty)
        }
    }

    private func link(_ seriesID: String) {
        store.link(recordID: record.id, to: seriesID)
        // Re-read the meeting against the open items of the list it now belongs to.
        library.extractActions(for: record)
    }

    private var proposalList: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Suggested changes").font(.headline)
                Spacer()
                Button("Accept all") { pending.forEach { store.accept($0.id, recordTitle: record.displayTitle) } }
            }
            ForEach(pending) { proposal in
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(description(proposal)).font(.callout)
                        Text("“\(proposal.quote)”").font(.caption).italic().foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Accept") { store.accept(proposal.id, recordTitle: record.displayTitle) }.controlSize(.small)
                    Button("Reject") { store.reject(proposal.id) }.controlSize(.small)
                }
                .padding(8)
                .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
            }
        }
    }

    private func description(_ proposal: MeetingProposal) -> String {
        guard case .update(let itemID, _, _, _, _) = proposal.change,
              let item = linked?.items.first(where: { $0.id == itemID }) else { return MeetingActionStore.describe(proposal.change) }
        return "\(item.text): \(MeetingActionStore.describe(proposal.change))"
    }
}

/// Editable table of one series' actions and decisions.
struct MeetingItemsTable: View {
    let seriesID: String
    @ObservedObject var store: MeetingActionStore
    var minHeight: CGFloat = 300
    @State private var statusFilter: MeetingItem.Status?
    @State private var editing: MeetingItem?

    private var items: [MeetingItem] {
        (store.series.first { $0.id == seriesID }?.items ?? []).filter { statusFilter == nil || $0.status == statusFilter }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Picker("Status", selection: $statusFilter) {
                    Text("All").tag(MeetingItem.Status?.none)
                    ForEach(MeetingItem.Status.allCases, id: \.self) { Text($0.title).tag(Optional($0)) }
                }
                .fixedSize()
                Spacer()
                Button { editing = MeetingItem(kind: .action, text: "") } label: { Label("Add", systemImage: "plus") }
            }
            Table(items) {
                TableColumn("Type") { item in Text(item.kind == .action ? "Action" : "Decision") }.width(70)
                TableColumn("Item") { item in Text(item.text).lineLimit(3).help(item.sourceQuote ?? "") }
                TableColumn("Owner") { item in Text(item.owner ?? "") }.width(110)
                TableColumn("Due") { item in Text(item.due ?? "") }.width(90)
                TableColumn("Status") { item in
                    Picker("", selection: Binding(get: { item.status }, set: { status in
                        var changed = item
                        changed.status = status
                        changed.history.append(.init(at: Date(), recordID: nil, summary: "status \(status.rawValue) (manual)"))
                        store.updateItem(changed, in: seriesID)
                    })) {
                        ForEach(MeetingItem.Status.allCases, id: \.self) { Text($0.title).tag($0) }
                    }
                    .labelsHidden()
                }.width(120)
                TableColumn("Remark") { item in Text(item.remark ?? "").lineLimit(3) }
            }
            .contextMenu(forSelectionType: MeetingItem.ID.self) { ids in
                if let id = ids.first, let item = items.first(where: { $0.id == id }) {
                    Button("Edit…") { editing = item }
                    Button("Delete", role: .destructive) { store.deleteItem(id, in: seriesID) }
                }
            } primaryAction: { ids in
                editing = ids.first.flatMap { id in items.first { $0.id == id } }
            }
            .frame(minHeight: minHeight)
        }
        .sheet(item: $editing) { item in
            MeetingItemEditor(item: item) { saved in
                if store.series.first(where: { $0.id == seriesID })?.items.contains(where: { $0.id == saved.id }) == true {
                    store.updateItem(saved, in: seriesID)
                } else if !saved.text.isEmpty {
                    store.addItem(saved, to: seriesID)
                }
                editing = nil
            } onCancel: { editing = nil }
        }
    }
}

private struct MeetingItemEditor: View {
    @State var item: MeetingItem
    let onSave: (MeetingItem) -> Void
    let onCancel: () -> Void

    var body: some View {
        Form {
            Picker("Type", selection: $item.kind) {
                Text("Action").tag(MeetingItem.Kind.action)
                Text("Decision").tag(MeetingItem.Kind.decision)
            }
            TextField("Item", text: $item.text, axis: .vertical)
            TextField("Owner", text: Binding(get: { item.owner ?? "" }, set: { item.owner = $0.isEmpty ? nil : $0 }))
            TextField("Due (YYYY-MM-DD)", text: Binding(get: { item.due ?? "" }, set: { item.due = $0.isEmpty ? nil : $0 }))
            Picker("Status", selection: $item.status) {
                ForEach(MeetingItem.Status.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            TextField("Remark", text: Binding(get: { item.remark ?? "" }, set: { item.remark = $0.isEmpty ? nil : $0 }), axis: .vertical)
            HStack {
                Spacer()
                Button("Cancel", action: onCancel)
                Button("Save") { onSave(item) }.keyboardShortcut(.defaultAction)
                    .disabled(item.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 460)
    }
}

/// All action lists: pick a series, edit it, import from or export to CSV/xlsx.
struct MeetingActionListsView: View {
    @ObservedObject var store: MeetingActionStore
    @ObservedObject var analytics: AudioAnalyticsStore
    @State private var selectedID: String?
    @State private var errorMessage: String?

    private var selected: MeetingSeries? { store.series.first { $0.id == (selectedID ?? store.series.first?.id) } }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Picker("Action list", selection: Binding(get: { selected?.id }, set: { selectedID = $0 })) {
                    ForEach(store.series) { Text($0.name).tag(Optional($0.id)) }
                }
                .fixedSize()
                Button { selectedID = store.createSeries(named: "New action list").id } label: { Label("New", systemImage: "plus") }
                Spacer()
                Button("Import…", action: importList)
                Menu("Export") {
                    Button("Excel (.xlsx)…") { export(xlsx: true) }
                    Button("CSV…") { export(xlsx: false) }
                }
                .fixedSize()
                .disabled(selected == nil)
                if let selected {
                    Button(role: .destructive) { store.deleteSeries(selected.id); selectedID = nil } label: { Image(systemName: "trash") }
                        .help("Delete this action list")
                }
            }
            if let selected {
                MeetingItemsTable(seriesID: selected.id, store: store)
            } else {
                Text("No action lists yet. They appear when you accept actions from a meeting, or import an existing list.")
                    .foregroundStyle(.secondary)
            }
            if let errorMessage { Text(errorMessage).foregroundStyle(.red).font(.caption) }
        }
        .padding(20)
    }

    private func importList() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.commaSeparatedText, UTType(filenameExtension: "xlsx") ?? .data]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task {
            do {
                let data = try Data(contentsOf: url)
                let rows = url.pathExtension.lowercased() == "xlsx"
                    ? try await MeetingActionsSpreadsheet.xlsxRows(data: data, filename: url.lastPathComponent)
                    : MeetingActionsSpreadsheet.parseCSV(String(decoding: data, as: UTF8.self))
                let items = MeetingActionsSpreadsheet.items(from: rows)
                guard !items.isEmpty else {
                    errorMessage = "No rows found. The first row needs a column such as Action, Item or Actie."
                    return
                }
                let target = selected ?? store.createSeries(named: url.deletingPathExtension().lastPathComponent)
                store.importItems(items, into: target.id)
                selectedID = target.id
                errorMessage = nil
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    private func export(xlsx: Bool) {
        guard let selected else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = selected.name + (xlsx ? ".xlsx" : ".csv")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let rows = MeetingActionsSpreadsheet.rows(selected.items) { id in analytics.record(withID: id)?.displayTitle }
        do {
            if xlsx { try MeetingActionsSpreadsheet.writeXLSX(rows, to: url) }
            else { try MeetingActionsSpreadsheet.csv(rows).write(to: url, atomically: true, encoding: .utf8) }
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
