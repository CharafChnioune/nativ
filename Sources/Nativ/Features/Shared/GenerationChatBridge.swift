import AppKit
import Combine
import Foundation
import NativServerKit
import SwiftUI

/// Small thread-safe availability snapshot; listing tools never performs model discovery or loading.
final class GenerationToolAvailability: @unchecked Sendable {
    static let shared = GenerationToolAvailability()
    private let lock = NSLock()
    private var ready: Set<String> = []
    func set(_ modality: GenerationModality, ready value: Bool) { lock.withLock { if value { ready.insert(modality.rawValue) } else { ready.remove(modality.rawValue) } } }
    func contains(_ modality: GenerationModality) -> Bool { lock.withLock { ready.contains(modality.rawValue) } }
}

struct GenerationChatJobReference: Codable, Equatable, Sendable {
    let storeID: String
    let jobID: String
    let sessionID: String
    let modality: GenerationModality
    enum CodingKeys: String, CodingKey { case storeID = "store_id", jobID = "job_id", sessionID = "session_id", modality }
    static func parse(_ content: String) -> Self? {
        guard let data = content.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(Self.self, from: data)
    }
}

@MainActor
final class GenerationChatLibraryHub: ObservableObject {
    let music: GenerationLibraryObserver
    let video: GenerationLibraryObserver
    private var subscriptions: [AnyCancellable] = []
    init(music: GenerationLibraryObserver, video: GenerationLibraryObserver) {
        self.music = music; self.video = video
        GenerationMediaAccess.hub = self
        for library in [music, video] { library.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }.store(in: &subscriptions) }
    }
    func library(_ modality: GenerationModality) -> GenerationLibraryObserver { modality == .music ? music : video }
}

extension Notification.Name { static let openGenerationSession = Notification.Name("NativOpenGenerationSession") }

struct GenerationChatJobCard: View {
    let reference: GenerationChatJobReference
    @EnvironmentObject private var hub: GenerationChatLibraryHub
    var body: some View {
        let library = hub.library(reference.modality)
        if library.storeID == reference.storeID, let job = library.jobs.first(where: { $0.jobID == reference.jobID }) {
            GenerationChatJobContent(job: job, library: library)
        } else {
            Label("Generation saved · reconnect to its original server to view this job.", systemImage: reference.modality == .music ? "waveform" : "film")
                .font(.callout).foregroundStyle(.secondary).padding(.vertical, 8)
        }
    }
}

private struct GenerationChatJobContent: View {
    let job: GenerationJob
    @StateObject private var model: GenerationWorkspaceModel
    init(job: GenerationJob, library: GenerationLibraryObserver) {
        self.job = job; _model = StateObject(wrappedValue: GenerationWorkspaceModel(library: library))
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            GenerationResultCard(job: job, viewModel: model)
            Button("Open in \(job.modality.rawValue.capitalized)") {
                NotificationCenter.default.post(name: .openGenerationSession, object: GenerationChatJobReference(storeID: job.storeID, jobID: job.jobID, sessionID: job.sessionID, modality: job.modality))
            }.font(.caption)
        }.padding(.top, 10)
    }
}
