import SwiftUI

struct MusicGenerationView: View {
    let model: NativModel
    @ObservedObject var viewModel: MusicGenerationViewModel
    let onSelectMode: (ChatWorkspaceMode) -> Void
    var body: some View {
        GenerationWorkspaceView(model: model, viewModel: viewModel, mode: .music, onSelectMode: onSelectMode)
    }
}
