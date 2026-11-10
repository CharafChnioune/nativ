import NativServerKit
import SwiftUI

struct GenerationWorkspaceView: View {
    let model: NativModel
    @ObservedObject var viewModel: GenerationWorkspaceModel
    @ObservedObject private var library: GenerationLibraryObserver
    let mode: ChatWorkspaceMode
    let onSelectMode: (ChatWorkspaceMode) -> Void
    let connectsOnAppear: Bool
    @ObservedObject private var connections = GenerationConnectionProfiles.shared
    @State private var showsSetup = false
    @State private var sessionTitle = ""
    @State private var renamingSession = false
    init(model: NativModel, viewModel: GenerationWorkspaceModel, mode: ChatWorkspaceMode, onSelectMode: @escaping (ChatWorkspaceMode) -> Void, connectsOnAppear: Bool = true) {
        self.model = model; self.viewModel = viewModel; library = viewModel.library; self.mode = mode; self.onSelectMode = onSelectMode; self.connectsOnAppear = connectsOnAppear
    }
    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 24) {
                    if viewModel.jobs.isEmpty { emptyState.frame(maxWidth: .infinity).padding(.top, 90) }
                    ForEach(viewModel.jobs.reversed()) { job in
                        GenerationResultCard(job: job, viewModel: viewModel)
                    }
                }
                .frame(maxWidth: 860).padding(.horizontal, 32).padding(.vertical, 24)
                .frame(maxWidth: .infinity)
            }
            if let error = viewModel.errorMessage ?? library.errorMessage {
                Label(error, systemImage: "exclamationmark.triangle").font(.callout).foregroundStyle(.orange)
                    .textSelection(.enabled).padding(.horizontal, 32).padding(.bottom, 10)
            }
            GenerationComposer(viewModel: viewModel, onSetup: { showsSetup = true })
                .frame(maxWidth: 680).padding(.horizontal, 32).padding(.bottom, 18)
                .frame(maxWidth: .infinity)
            GenerationCompactPlayer(playback: viewModel.playback)
        }
        .background(Color.nativMainContentBackground)
        .task(id: connections.connection(using: model)) { if connectsOnAppear { library.connect(connections.connection(using: model), profileID: connections.selectedID) } }
        .onChange(of: library.profiles.map(\.id)) { _, _ in viewModel.applyInitialProfile() }
        .sheet(isPresented: $showsSetup) { GenerationSetupView(library: library, model: model) }
        .alert("Rename session", isPresented: $renamingSession) {
            TextField("Title", text: $sessionTitle)
            Button("Save") {
                guard let id = viewModel.selectedSessionID else { return }
                Task { do { try await library.updateSession(id, title: sessionTitle) } catch { viewModel.errorMessage = error.localizedDescription } }
            }
            Button("Cancel", role: .cancel) {}
        }
    }
    private var header: some View {
        HStack(spacing: 12) {
            ChatWorkspacePicker(selection: mode, onSelect: onSelectMode)
            Spacer()
            Menu {
                Button("All results") { viewModel.selectedSessionID = nil }
                ForEach(viewModel.visibleSessions) { session in
                    Button(session.title.isEmpty ? "Untitled" : session.title) { viewModel.selectedSessionID = session.id }
                }
                if viewModel.selectedSessionID != nil {
                    Divider()
                    Button("Rename session…") {
                        sessionTitle = viewModel.visibleSessions.first { $0.id == viewModel.selectedSessionID }?.title ?? ""
                        renamingSession = true
                    }
                    Button("Hide session") {
                        guard let id = viewModel.selectedSessionID else { return }
                        Task { do { try await library.updateSession(id, hidden: true); viewModel.selectedSessionID = nil } catch { viewModel.errorMessage = error.localizedDescription } }
                    }
                }
            } label: { Label("History", systemImage: "clock") }
            Button { viewModel.newDraft() } label: { Image(systemName: "square.and.pencil") }.help("New draft")
            Button { showsSetup = true } label: { Image(systemName: "slider.horizontal.3") }.help("Providers and runtimes")
        }
        .buttonStyle(.plain).padding(.horizontal, 32).frame(height: 54)
    }
    private var emptyState: some View {
        VStack(spacing: 14) {
            Image(systemName: viewModel.modality == .music ? "waveform" : "film")
                .font(.system(size: 44, weight: .light)).foregroundStyle(.secondary)
            Text(viewModel.modality == .music ? "Create with Music" : "Create with Video").font(.headline)
            Text(library.storeID == nil ? "Start the server and configure its API key to connect to your media library." : "Choose a model and describe what you want to create. Generation continues while the server remains running.")
                .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: 440)
            if library.profiles.allSatisfy({ $0.readiness != "ready" }) {
                Button("Set up models and providers…") { showsSetup = true }.buttonStyle(.bordered)
            }
        }
    }
}
