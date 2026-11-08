import AppKit
import ImageIO
import SwiftUI

struct GenerationInputPreview: View {
    let url: URL
    let aspect: Double
    @State private var image: CGImage?
    var body: some View {
        ZStack {
            Color.black
            if let image { Image(decorative: image, scale: 1).resizable().scaledToFit() }
            else { ProgressView().controlSize(.mini) }
        }
        .aspectRatio(max(0.1, aspect), contentMode: .fit).frame(width: 100, height: 70)
        .task(id: url) {
            let thumbnail = await Task.detached(priority: .utility) {
                guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil as CGImage? }
                let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true, kCGImageSourceThumbnailMaxPixelSize: 320]
                return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
            }.value
            guard !Task.isCancelled else { return }
            image = thumbnail
        }
        .accessibilityLabel("Reference image preview")
    }
}
