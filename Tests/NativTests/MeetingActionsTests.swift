import XCTest
import NativServerKit

@MainActor
final class MeetingActionsTests: XCTestCase {
    private let transcript = """
        We agreed to launch the beta on Friday.
        Sam will send the release notes to the team before Thursday.
        The invoice check is finished now, so that one is done.
        """

    private func record(_ id: String = "m1", title: String? = "Weekly product sync", app: String? = "Zoom") -> AudioTranscriptionRecord {
        AudioTranscriptionRecord(id: id, recordedAt: Date(timeIntervalSince1970: 1_794_000_000), updatedAt: .distantPast,
            durationSeconds: 60, transcript: transcript, modelID: "test", applicationName: app, kind: .meeting,
            title: title, audioFileName: nil, summary: nil)
    }

    private func store() -> MeetingActionStore {
        MeetingActionStore(storageURL: FileManager.default.temporaryDirectory
            .appendingPathComponent("meeting-actions-\(UUID().uuidString).json"))
    }

    /// Opt-in local model check: two meetings of one series. Set NATIV_ACTIONS_TEST_MODEL (and _URL).
    func testTwoMeetingsWithLocalModel() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let model = environment["NATIV_ACTIONS_TEST_MODEL"] else {
            throw XCTSkip("Set NATIV_ACTIONS_TEST_MODEL to run the local model check")
        }
        let client = NativChatClient(baseURL: URL(string: environment["NATIV_ACTIONS_TEST_URL"] ?? "http://127.0.0.1:8080")!,
                                     apiKey: environment["NATIV_ACTIONS_TEST_KEY"] ?? "", resourceTimeout: 600)
        let complete: @Sendable (MLXChatCompletionRequest) async throws -> (content: String, finishReason: String?) = { request in
            let completion = try await client.completeChat(request)
            return (completion.content, completion.finishReason)
        }
        func meeting(_ id: String, _ text: String) -> AudioTranscriptionRecord {
            AudioTranscriptionRecord(id: id, recordedAt: Date(timeIntervalSince1970: 1_794_000_000), updatedAt: .distantPast,
                durationSeconds: 300, transcript: text, modelID: "test", applicationName: "Teams", kind: .meeting,
                title: "Teamoverleg marketing", audioFileName: nil, summary: nil)
        }
        let first = meeting("m1", """
            Goedemorgen allemaal. Eerst de lancering van de nieuwe website.
            Na overleg hebben we besloten dat de website op 1 december live gaat.
            Sanne, kun jij de teksten voor de homepage aanleveren? Ja, ik lever de teksten uiterlijk vrijdag aan.
            Pieter zegt: ik regel de offerte van de fotograaf voor volgende week.
            Misschien kunnen we ooit ook een podcast beginnen, maar dat is gewoon een idee.
            """)
        let store = store()
        let series = store.createSeries(named: "Teamoverleg marketing", applicationName: "Teams")
        store.link(recordID: "m1", to: series.id)
        var proposals = try await MeetingActionExtractor.extract(record: first, openItems: [], maxTokens: 2048, contextSize: nil,
            languageInstruction: "Dutch", complete: complete, modelID: model)
        print("MEETING 1 PROPOSALS:", proposals.map { MeetingActionStore.describe($0.change) + " | " + $0.quote })
        store.replacePendingProposals(proposals, for: "m1")
        for proposal in store.proposals(for: "m1") { store.accept(proposal.id, recordTitle: nil) }
        let items = store.seriesContaining(recordID: "m1")?.items ?? []
        XCTAssertTrue(items.contains { $0.kind == .decision && $0.text.lowercased().contains("december") }, "\(items)")
        XCTAssertTrue(items.contains { $0.kind == .action && $0.owner?.contains("Sanne") == true }, "\(items)")
        XCTAssertFalse(items.contains { $0.text.lowercased().contains("podcast") }, "An idea is not an action")

        let second = meeting("m2", """
            Even de acties van vorige week langs.
            Sanne: de teksten voor de homepage zijn klaar en staan in de gedeelde map.
            Pieter: de offerte van de fotograaf is nog niet binnen, ik bel hem morgen.
            Nieuw: Joris gaat de nieuwsbrief over de lancering schrijven voor 25 november.
            """)
        store.link(recordID: "m2", to: series.id)
        proposals = try await MeetingActionExtractor.extract(record: second, openItems: items.filter { $0.status == .open },
            maxTokens: 2048, contextSize: nil, languageInstruction: "Dutch", complete: complete, modelID: model)
        print("MEETING 2 PROPOSALS:", proposals.map { MeetingActionStore.describe($0.change) + " | " + $0.quote })
        let sanne = try XCTUnwrap(items.first { $0.owner?.contains("Sanne") == true })
        XCTAssertTrue(proposals.contains {
            if case .update(sanne.id, .done, _, _, _) = $0.change { return true }
            return false
        }, "Completed homepage texts should be proposed as done")
        XCTAssertTrue(proposals.contains {
            if case .add(.action, _, let owner, _) = $0.change { return owner?.contains("Joris") == true }
            return false
        }, "The new newsletter action should be proposed")
    }

    func testOnlyGroundedProposalsForKnownItemsSurvive() {
        let raw = """
            ```json
            {"decisions":[
              {"text":"Launch beta on Friday","quote":"We agreed to launch the beta"}
            ],
            "actions":[
              {"text":"Send release notes. Status: open. Quote: 'x'","owner":"Sam","due":"2026-11-12","quote":"Sam will send the release notes"},
              {"text":"Check the invoice","owner":"","due":"","quote":"The invoice check is finished now"},
              {"text":"Invented task","owner":"","due":"soon","quote":"nobody said these words here"}
            ],
            "updates":[
              {"item_id":"A1","status":"done","owner":"","due":"","remark":"","quote":"The invoice check is finished now"},
              {"item_id":"A9","status":"done","owner":"","due":"","remark":"","quote":"The invoice check is finished now"},
              {"item_id":"a1","status":"open","owner":"Lee","due":"","remark":"","quote":"The invoice check is finished now"}
            ]}
            ```
            """
        let invoice = MeetingItem(id: "inv", kind: .action, text: "Check the invoice", owner: "Lee")
        let proposals = MeetingActionExtractor.parse(raw, recordID: "m1", transcript: transcript, existing: [invoice])
        XCTAssertEqual(proposals.map(\.change), [
            .add(kind: .decision, text: "Launch beta on Friday", owner: nil, due: nil),
            .add(kind: .action, text: "Send release notes", owner: "Sam", due: "2026-11-12"),
            .update(itemID: "inv", status: .done, owner: nil, due: nil, remark: nil),
        ], "Cleans stuffed text, skips re-added items, unknown references and no-op updates")
        XCTAssertTrue(MeetingActionExtractor.parse("not json", recordID: "m1", transcript: transcript, existing: []).isEmpty)
    }

    func testExtractCallsTheModelPerChunkAndDeduplicates() async throws {
        let json = #"{"decisions":[],"actions":[{"text":"Send release notes","owner":"Sam","due":"","quote":"Sam will send the release notes"}],"updates":[]}"#
        let proposals = try await MeetingActionExtractor.extract(
            record: record(), openItems: [], maxTokens: 512, contextSize: nil, languageInstruction: "English",
            complete: { request in
                (request.responseFormat == nil ? "" : json, "stop")
            }, modelID: "test")
        XCTAssertEqual(proposals.count, 1)
        XCTAssertEqual(MeetingActionExtractor.chunks("a\nb\nc", maximumBytes: 3), ["a\nb", "c"])
    }

    func testAcceptingProposalsBuildsAndUpdatesTheSeriesList() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("meeting-actions-\(UUID().uuidString).json")
        let store = MeetingActionStore(storageURL: url)
        let series = store.createSeries(named: "Weekly product sync", applicationName: "Zoom")
        store.link(recordID: "m1", to: series.id)
        store.replacePendingProposals([
            MeetingProposal(recordID: "m1", change: .add(kind: .action, text: "Send release notes", owner: "Sam", due: nil), quote: "Sam will send"),
            MeetingProposal(recordID: "m1", change: .add(kind: .decision, text: "Launch Friday", owner: nil, due: nil), quote: "We agreed"),
        ], for: "m1")
        for proposal in store.proposals(for: "m1") { store.accept(proposal.id, recordTitle: nil) }
        var items = try XCTUnwrap(store.seriesContaining(recordID: "m1")).items
        XCTAssertEqual(items.map(\.status), [.open, .done], "Decisions are recorded as settled")
        XCTAssertEqual(items.first?.sourceRecordID, "m1")

        store.link(recordID: "m2", to: series.id)
        let actionID = items[0].id
        store.replacePendingProposals([
            MeetingProposal(recordID: "m2", change: .update(itemID: actionID, status: .done, owner: nil, due: nil, remark: "Sent Thursday"), quote: "q"),
            MeetingProposal(recordID: "m2", change: .add(kind: .action, text: "Rejected idea", owner: nil, due: nil), quote: "q"),
        ], for: "m2")
        let pending = store.proposals(for: "m2")
        store.accept(pending[0].id, recordTitle: nil)
        store.reject(pending[1].id)
        items = try XCTUnwrap(store.seriesContaining(recordID: "m2")).items
        XCTAssertEqual(items.count, 2)
        XCTAssertEqual(items[0].status, .done)
        XCTAssertEqual(items[0].remark, "Sent Thursday")
        XCTAssertEqual(items[0].history.count, 2)

        let reloaded = MeetingActionStore(storageURL: url)
        XCTAssertEqual(reloaded.series, store.series)
        XCTAssertEqual(reloaded.proposals.map(\.decision), [.accepted, .accepted, .accepted, .rejected])
    }

    func testSeriesSuggestionUsesAppTitleAndKnownOwners() {
        let store = store()
        store.createSeries(named: "Marketing standup", applicationName: "Teams")
        let product = store.createSeries(named: "Weekly product sync", applicationName: "Zoom")
        XCTAssertEqual(store.suggestedSeries(for: record(), speakerNames: [])?.id, product.id)
        XCTAssertNil(store.suggestedSeries(for: record(title: "Dentist", app: "FaceTime"), speakerNames: []))
    }

    func testCSVRoundTripAndDutchImport() {
        let rows = [["Type", "Item"], ["action", "Quote \"this\", then\nnew line"]]
        XCTAssertEqual(MeetingActionsSpreadsheet.parseCSV(MeetingActionsSpreadsheet.csv(rows)), rows)

        let dutch = "Actie;Eigenaar;Status;Opmerking;Deadline\nOfferte sturen;Sam;Bezig;Wacht op prijs;2026-12-01\nBudget checken;;Geparkeerd;;\n"
        let items = MeetingActionsSpreadsheet.items(from: MeetingActionsSpreadsheet.parseCSV(dutch))
        XCTAssertEqual(items.map(\.text), ["Offerte sturen", "Budget checken"])
        XCTAssertEqual(items.map(\.status), [.inProgress, .open])
        XCTAssertEqual(items[0].owner, "Sam")
        XCTAssertEqual(items[0].due, "2026-12-01")
        XCTAssertEqual(items[1].remark, "Status: Geparkeerd", "Unknown statuses are kept, not lost")
        XCTAssertTrue(MeetingActionsSpreadsheet.items(from: [["Foo", "Bar"], ["x", "y"]]).isEmpty)

        let formula = MeetingActionsSpreadsheet.csv([["Item"], ["=HYPERLINK(\"http://x\")"]])
        XCTAssertTrue(formula.contains("\"'=HYPERLINK"), "Formula cells are neutralised: \(formula)")
        XCTAssertEqual(MeetingActionsSpreadsheet.csv([["a;=1+1", " @SUM(1)"]]), "\"a;=1+1\",\"' @SUM(1)\"\r\n",
                       "Every field is quoted and leading whitespace does not hide a formula")
        XCTAssertEqual(MeetingActionsSpreadsheet.items(from: MeetingActionsSpreadsheet.parseCSV(formula)).map(\.text), ["=HYPERLINK(\"http://x\")"])
    }

    func testXLSXExportReadsBackThroughTheImporter() async throws {
        let item = MeetingItem(kind: .action, text: "Send <notes> & slides", owner: "Sam", due: "2026-11-12", status: .done, remark: "Done")
        let rows = MeetingActionsSpreadsheet.rows([item]) { _ in nil }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("actions-\(UUID().uuidString).xlsx")
        defer { try? FileManager.default.removeItem(at: url) }
        try MeetingActionsSpreadsheet.writeXLSX(rows, to: url)
        let read = try await MeetingActionsSpreadsheet.xlsxRows(data: Data(contentsOf: url), filename: "actions.xlsx")
        XCTAssertEqual(read.first, MeetingActionsSpreadsheet.header)
        let imported = MeetingActionsSpreadsheet.items(from: read)
        XCTAssertEqual(imported.first?.text, item.text)
        XCTAssertEqual(imported.first?.status, .done)
        XCTAssertEqual(MeetingActionsSpreadsheet.columnName(0), "A")
        XCTAssertEqual(MeetingActionsSpreadsheet.columnName(26), "AA")
    }
}
