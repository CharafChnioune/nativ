import Foundation

@MainActor
final class ControlPanelSharedDependencies {
    let mcpHost = MCPHostManager()
    let systemMonitor = SystemMonitorStore()
    let launchAtLogin = LaunchAtLoginController()
    let persistedDataChanges = PersistedDataChangeHub()
    let inferenceActivity = InferenceActivityCoordinator()
    let musicLibrary = GenerationLibraryObserver(modality: .music)
    let videoLibrary = GenerationLibraryObserver(modality: .video)
    lazy var generationHub = GenerationChatLibraryHub(music: musicLibrary, video: videoLibrary)
    let generationPlayback = GenerationPlaybackCoordinator.shared
    let projects = ChatProjectStore()
    let chatSearch = ChatSearchLibrary(storageURL: ChatSearchStore.defaultURL)
    let fileIndex = ArtifactFileIndexCoordinator()
    private let artifactChangeOrigin = UUID()
    lazy var artifactTrash = ArtifactTrash(
        isActive: { [inferenceActivity] workspace, id in
            switch workspace {
            case .chat: inferenceActivity.isActive(.chat(id))
            case .imageGeneration: inferenceActivity.isActive(.imageGeneration(id))
            case .musicGeneration, .videoGeneration: false
            }
        },
        didChange: { [persistedDataChanges, artifactChangeOrigin] kind in
            persistedDataChanges.send(kind, originWindowID: artifactChangeOrigin)
        }
    )

    init() {
        let references = GenerationChatReferenceBridge(activity: inferenceActivity, changes: persistedDataChanges)
        musicLibrary.chatReferences = references
        videoLibrary.chatReferences = references
        systemMonitor.startDiagnosticHistory()
    }
}

@MainActor
final class ControlPanelDependencies: ObservableObject {
    let mcpHost: MCPHostManager
    let systemMonitor: SystemMonitorStore
    let launchAtLogin: LaunchAtLoginController
    let windowID: UUID
    let persistedDataChanges: PersistedDataChangeHub
    let inferenceActivity: InferenceActivityCoordinator
    let musicLibrary: GenerationLibraryObserver
    let videoLibrary: GenerationLibraryObserver
    let generationHub: GenerationChatLibraryHub
    let generationPlayback: GenerationPlaybackCoordinator
    let projects: ChatProjectStore
    let fileIndex: ArtifactFileIndexCoordinator
    let chatSearch: ChatSearchLibrary
    let artifactTrash: ArtifactTrash

    lazy var chat = ChatViewModel(
        windowID: windowID,
        persistedDataChanges: persistedDataChanges,
        inferenceActivity: inferenceActivity,
        projectStore: projects,
        searchLibrary: chatSearch
    )
    lazy var imageGeneration = ImageGenerationViewModel(
        windowID: windowID,
        persistedDataChanges: persistedDataChanges,
        inferenceActivity: inferenceActivity
    )
    lazy var musicGeneration = MusicGenerationViewModel(library: musicLibrary, playback: generationPlayback)
    lazy var videoGeneration = VideoGenerationViewModel(library: videoLibrary, playback: generationPlayback)
    lazy var artifacts = ArtifactStore(persistedDataChanges: persistedDataChanges, fileIndex: fileIndex, trash: artifactTrash, generationLibraries: [musicLibrary, videoLibrary])
    lazy var dashboard = DashboardViewModel()
    lazy var downloads = HuggingFaceDownloadManager.shared
    lazy var embeddingLibrary = LocalModelLibrary()
    lazy var routineModelLibrary = LocalModelLibrary()

    init(
        shared: ControlPanelSharedDependencies = .init(),
        windowID: UUID = UUID()
    ) {
        mcpHost = shared.mcpHost
        systemMonitor = shared.systemMonitor
        launchAtLogin = shared.launchAtLogin
        self.windowID = windowID
        persistedDataChanges = shared.persistedDataChanges
        inferenceActivity = shared.inferenceActivity
        musicLibrary = shared.musicLibrary
        videoLibrary = shared.videoLibrary
        generationHub = shared.generationHub
        generationPlayback = shared.generationPlayback
        projects = shared.projects
        fileIndex = shared.fileIndex
        chatSearch = shared.chatSearch
        artifactTrash = shared.artifactTrash
    }
}
