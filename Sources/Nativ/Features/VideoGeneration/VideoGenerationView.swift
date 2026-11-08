import SwiftUI

struct VideoGenerationView: View {
    let model: NativModel
    @ObservedObject var viewModel: VideoGenerationViewModel
    let onSelectMode: (ChatWorkspaceMode) -> Void
    var body: some View {
        GenerationWorkspaceView(model: model, viewModel: viewModel, mode: .video, onSelectMode: onSelectMode)
    }
}
