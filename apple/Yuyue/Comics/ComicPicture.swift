import SwiftUI

/// One page, decoded no bigger than shown; a dark card while it loads, never a white one.
struct ComicPicture: View {
    let url: URL
    let size: CGSize
    var crop = false
    @Environment(\.displayScale) private var scale
    @State private var image: CGImage?

    private var pixels: Int { Int(max(size.width, size.height) * scale) }

    var body: some View {
        ZStack {
            Color(red: 20 / 255, green: 20 / 255, blue: 22 / 255)
            if let image {
                Image(decorative: image, scale: 1).resizable().interpolation(.high)
            }
        }
        .frame(width: size.width, height: size.height)
        .task(id: "\(url.path)#\(pixels)#\(crop)") {
            if let hit = ComicImages.shared.cached(url, pixels, crop: crop) { image = hit; return }
            image = await ComicImages.shared.image(url, pixels: pixels, crop: crop)
        }
    }
}
