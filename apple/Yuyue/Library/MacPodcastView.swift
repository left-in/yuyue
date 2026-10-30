import SwiftUI

/// 播客: a place held in the sidebar. Nothing behind it yet.
struct MacPodcastView: View {
    var body: some View {
        VStack(spacing: 10) {
            Image("radio").resizable().renderingMode(.template).scaledToFit().frame(width: 30, height: 30).foregroundStyle(YYColor.t3)
            Text("播客").font(.yy(size: 13, weight: .semibold)).foregroundStyle(YYColor.t1)
            Text("即将推出").font(.yy(size: 12)).foregroundStyle(YYColor.t2)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .combine)
    }
}
