import Foundation

/// One row of a meeting series' action and decision list.
struct MeetingItem: Codable, Equatable, Identifiable, Sendable {
    enum Kind: String, Codable, CaseIterable, Sendable { case action, decision }
    enum Status: String, Codable, CaseIterable, Sendable { case open, inProgress = "in_progress", done, dropped }
    struct Change: Codable, Equatable, Sendable {
        let at: Date
        let recordID: String?
        let summary: String
    }

    var id = UUID().uuidString
    var kind: Kind
    var text: String
    var owner: String?
    var due: String?  // ISO date (yyyy-MM-dd) or nil
    var status: Status = .open
    var remark: String?
    var sourceRecordID: String?
    var sourceQuote: String?
    var updatedAt = Date()
    var history: [Change] = []
}

/// A change the model proposes from one meeting; nothing applies until the user accepts it.
struct MeetingProposal: Codable, Equatable, Identifiable, Sendable {
    enum Decision: String, Codable, Sendable { case pending, accepted, rejected }
    enum Change: Codable, Equatable, Sendable {
        case add(kind: MeetingItem.Kind, text: String, owner: String?, due: String?)
        case update(itemID: String, status: MeetingItem.Status?, owner: String?, due: String?, remark: String?)
    }

    var id = UUID().uuidString
    let recordID: String
    let change: Change
    let quote: String
    var decision: Decision = .pending
}

struct MeetingSeries: Codable, Equatable, Identifiable, Sendable {
    var id = UUID().uuidString
    var name: String
    var items: [MeetingItem] = []
    var recordIDs: [String] = []
    var applicationName: String?
}

@MainActor
final class MeetingActionStore: ObservableObject {
    static let shared = MeetingActionStore()

    @Published private(set) var series: [MeetingSeries] = []
    @Published private(set) var proposals: [MeetingProposal] = []
    @Published private(set) var extractingRecordIDs = Set<String>()
    private let storageURL: URL

    private struct Storage: Codable {
        let version: Int
        let series: [MeetingSeries]
        let proposals: [MeetingProposal]
    }

    init(storageURL: URL? = nil) {
        self.storageURL = storageURL ?? Self.defaultStorageURL
        if let data = try? Data(contentsOf: self.storageURL),
           let storage = try? JSONDecoder().decode(Storage.self, from: data) {
            series = storage.series
            proposals = storage.proposals
        }
    }

    // MARK: Series

    func seriesContaining(recordID: String) -> MeetingSeries? {
        series.first { $0.recordIDs.contains(recordID) }
    }

    @discardableResult
    func createSeries(named name: String, applicationName: String? = nil) -> MeetingSeries {
        let created = MeetingSeries(name: name.trimmingCharacters(in: .whitespacesAndNewlines), applicationName: applicationName)
        series.append(created)
        save()
        return created
    }

    func link(recordID: String, to seriesID: String) {
        for index in series.indices { series[index].recordIDs.removeAll { $0 == recordID } }
        guard let index = series.firstIndex(where: { $0.id == seriesID }) else { return save() }
        series[index].recordIDs.append(recordID)
        save()
    }

    func deleteSeries(_ seriesID: String) {
        guard let removed = series.first(where: { $0.id == seriesID }) else { return }
        series.removeAll { $0.id == seriesID }
        let itemIDs = Set(removed.items.map(\.id))
        proposals.removeAll {
            if case .update(let itemID, _, _, _, _) = $0.change { return itemIDs.contains(itemID) }
            return false
        }
        save()
    }

    /// Best existing series for a recording: same app, shared title words and known speakers.
    /// Explainable, model-free scoring; returns nil when nothing clearly matches.
    func suggestedSeries(for record: AudioTranscriptionRecord, speakerNames: [String]) -> MeetingSeries? {
        let words = Self.titleWords(record.title)
        let names = Set(speakerNames.map { $0.lowercased() })
        let scored = series.compactMap { candidate -> (MeetingSeries, Int)? in
            var score = 0
            if let app = record.applicationName, app == candidate.applicationName { score += 1 }
            score += 2 * Self.titleWords(candidate.name).intersection(words).count
            let owners = Set(candidate.items.compactMap { $0.owner?.lowercased() })
            score += names.intersection(owners).count
            return score >= 2 ? (candidate, score) : nil
        }
        return scored.max { $0.1 < $1.1 }?.0
    }

    static func titleWords(_ title: String?) -> Set<String> {
        let ignored: Set<String> = ["meeting", "recording", "vergadering", "overleg", "call", "the", "de", "het", "en", "and"]
        return Set((title ?? "").lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init)
            .filter { $0.count > 2 && !ignored.contains($0) })
    }

    // MARK: Items

    func addItem(_ item: MeetingItem, to seriesID: String) {
        guard let index = series.firstIndex(where: { $0.id == seriesID }) else { return }
        series[index].items.append(item)
        save()
    }

    func updateItem(_ item: MeetingItem, in seriesID: String) {
        guard let s = series.firstIndex(where: { $0.id == seriesID }),
              let i = series[s].items.firstIndex(where: { $0.id == item.id }) else { return }
        var updated = item
        updated.updatedAt = Date()
        series[s].items[i] = updated
        save()
    }

    func deleteItem(_ itemID: String, in seriesID: String) {
        guard let s = series.firstIndex(where: { $0.id == seriesID }) else { return }
        series[s].items.removeAll { $0.id == itemID }
        save()
    }

    func importItems(_ items: [MeetingItem], into seriesID: String) {
        guard let index = series.firstIndex(where: { $0.id == seriesID }) else { return }
        series[index].items += items
        save()
    }

    // MARK: Proposals

    func proposals(for recordID: String) -> [MeetingProposal] {
        proposals.filter { $0.recordID == recordID }
    }

    func setExtracting(_ recordID: String, _ active: Bool) {
        if active { extractingRecordIDs.insert(recordID) } else { extractingRecordIDs.remove(recordID) }
    }

    /// Replaces the pending proposals of a recording; decided ones stay as history.
    func replacePendingProposals(_ new: [MeetingProposal], for recordID: String) {
        proposals.removeAll { $0.recordID == recordID && $0.decision == .pending }
        proposals += new
        save()
    }

    func reject(_ proposalID: String) {
        guard let index = proposals.firstIndex(where: { $0.id == proposalID }) else { return }
        proposals[index].decision = .rejected
        save()
    }

    /// Applies an accepted proposal to the recording's series; adds go to a new series if none is linked.
    func accept(_ proposalID: String, recordTitle: String?) {
        guard let p = proposals.firstIndex(where: { $0.id == proposalID }), proposals[p].decision == .pending else { return }
        let proposal = proposals[p]
        var seriesIndex = series.firstIndex { $0.recordIDs.contains(proposal.recordID) }
        if seriesIndex == nil {
            series.append(MeetingSeries(name: recordTitle ?? "Meeting actions", recordIDs: [proposal.recordID]))
            seriesIndex = series.count - 1
        }
        guard let s = seriesIndex else { return }
        let change = MeetingItem.Change(at: Date(), recordID: proposal.recordID, summary: Self.describe(proposal.change))
        switch proposal.change {
        case .add(let kind, let text, let owner, let due):
            series[s].items.append(MeetingItem(kind: kind, text: text, owner: owner, due: due,
                                               status: kind == .decision ? .done : .open,
                                               sourceRecordID: proposal.recordID, sourceQuote: proposal.quote,
                                               history: [change]))
        case .update(let itemID, let status, let owner, let due, let remark):
            guard let i = series[s].items.firstIndex(where: { $0.id == itemID }) else { return }
            if let status { series[s].items[i].status = status }
            if let owner { series[s].items[i].owner = owner }
            if let due { series[s].items[i].due = due }
            if let remark {
                let existing = series[s].items[i].remark ?? ""
                series[s].items[i].remark = existing.isEmpty ? remark : existing + "\n" + remark
            }
            series[s].items[i].updatedAt = Date()
            series[s].items[i].history.append(change)
        }
        proposals[p].decision = .accepted
        save()
    }

    static func describe(_ change: MeetingProposal.Change) -> String {
        switch change {
        case .add(let kind, let text, _, _): "New \(kind.rawValue): \(text)"
        case .update(_, let status, let owner, let due, let remark):
            [status.map { "status \($0.rawValue)" }, owner.map { "owner \($0)" }, due.map { "due \($0)" }, remark.map { "remark: \($0)" }]
                .compactMap { $0 }.joined(separator: ", ")
        }
    }

    // MARK: Persistence

    private func save() {
        do {
            try FileManager.default.createDirectory(at: storageURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(Storage(version: 1, series: series, proposals: proposals)).write(to: storageURL, options: .atomic)
        } catch {
            NSLog("Nativ could not save meeting actions: %@", error.localizedDescription)
        }
    }

    private static var defaultStorageURL: URL {
        let applicationSupport = (try? FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true
        )) ?? FileManager.default.temporaryDirectory
        return applicationSupport
            .appendingPathComponent(NativBuildIdentity.applicationSupportDirectoryName, isDirectory: true)
            .appendingPathComponent("Meeting Actions.json")
    }
}
