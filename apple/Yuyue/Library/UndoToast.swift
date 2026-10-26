import SwiftUI

/// The note after something happened. A plain one is a small white capsule that flashes at the
/// top (docs/design: 第三轮 Q · 3); one that can be undone is the wide glass banner instead
/// (删除后撤销 · V6 with button B3), so the two never look alike.
struct UndoToast: View {
    let toast: Library.Toast
    let undo: () -> Void

    /// 即刻's green tick for a plain note; a deletion is red.
    static let done = Color(red: 0x2D / 255, green: 0xBE / 255, blue: 0x60 / 255)

    /// Every screen puts it centred at the top, coming down from above.
    static var transition: AnyTransition {
        .move(edge: .top).combined(with: .opacity).combined(with: .scale(scale: 0.94, anchor: .top))
    }

    var body: some View {
        if toast.undo != nil {
            UndoBanner(toast: toast, undo: undo)
        } else {
            NoteCapsule(toast: toast)
        }
    }
}

/// White capsule, as wide as its one line: a round red or green dot with a tick, then the words.
private struct NoteCapsule: View {
    let toast: Library.Toast

    var body: some View {
        HStack(spacing: 7) {
            ZStack {
                Circle().fill(toast.danger ? YYColor.danger : UndoToast.done)
                Image(systemName: "checkmark")
                    .font(.yy(size: 8, weight: .heavy))
                    .foregroundStyle(.white)
            }
            .frame(width: 15, height: 15)
            Text(toast.detail.isEmpty ? toast.title : "\(toast.title) · \(toast.detail)")
                .font(.yy(size: 11.5 * 1.2))
                .foregroundStyle(YYColor.t1)
                .lineLimit(1)
        }
        .padding(.leading, 11 * 1.2)
        .padding(.trailing, 14 * 1.2)
        .frame(height: 34 * 1.2)
        .background(YYColor.card, in: .capsule)
        .overlay(Capsule().strokeBorder(YYColor.line, lineWidth: 0.5))
        .shadow(color: .black.opacity(0.09), radius: 12, y: 4)
        .frame(maxWidth: 420)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.updatesFrequently)
    }
}

/// The glass banner across the top: a red ring counting the seconds down, the two lines, and a
/// round glass button with the undo arrow. At 0 the ring closes into a red tick and the button
/// goes; Library takes the toast off a moment later, which lifts the banner away.
private struct UndoBanner: View {
    let toast: Library.Toast
    let undo: () -> Void
    @AppStorage("appearance.tint") private var tintID = YYTint.blue.id
    private var tint: YYTint { YYTint.all.first { $0.id == tintID } ?? .blue }
    @State private var start = Date.now
    @State private var done = false

    var body: some View {
        HStack(spacing: 12) {
            TimelineView(.animation(paused: done)) { context in
                let left = max(0, 1 - context.date.timeIntervalSince(start) / Library.undoSeconds)
                CountdownRing(left: left, done: done)
            }
            .frame(width: 26 * 1.2, height: 26 * 1.2)
            VStack(alignment: .leading, spacing: 2) {
                Text(toast.title)
                    .font(.yy(size: 13 * 1.2, weight: .semibold))
                    .foregroundStyle(YYColor.t1)
                if !toast.detail.isEmpty {
                    Text(toast.detail)
                        .font(.yy(size: 10.5 * 1.2))
                        .foregroundStyle(YYColor.t2)
                }
            }
            .lineLimit(1)
            .frame(maxWidth: .infinity, alignment: .leading)
            // B3: a round glass button with only the arrow; it fades as the tick comes.
            Button(action: undo) {
                Image(systemName: "arrow.uturn.backward")
                    .font(.yy(size: 15, weight: .semibold))
                    .foregroundStyle(tint.accent)
                    .frame(width: 36 * 1.2, height: 36 * 1.2)
                    .background(YYColor.t1.opacity(0.06), in: .circle)
                    .overlay(Circle().strokeBorder(YYColor.line, lineWidth: 0.5))
                    .contentShape(.circle)
            }
            .buttonStyle(.plain)
            .keyboardShortcut("z")
            .accessibilityLabel("撤销")
            .opacity(done ? 0 : 1)
            .scaleEffect(done ? 0.9 : 1)
            .disabled(done)
        }
        .padding(.leading, 13 * 1.2)
        .padding(.trailing, 10 * 1.2)
        .padding(.vertical, 11 * 1.2)
        // The prototype's glass: near-white over a blur of the page.
        .background(YYColor.glass, in: .rect(cornerRadius: 20 * 1.2))
        .background(.ultraThinMaterial, in: .rect(cornerRadius: 20 * 1.2))
        .overlay(RoundedRectangle(cornerRadius: 20 * 1.2).strokeBorder(YYColor.line, lineWidth: 0.5))
        .shadow(color: .black.opacity(0.16), radius: 18, y: 8)
        .frame(maxWidth: 460)
        .accessibilityElement(children: .combine)
        .accessibilityAction(named: "撤销") { if !done { undo() } }
        .task(id: toast.id) {
            start = .now
            done = false
            try? await Task.sleep(for: .seconds(Library.undoSeconds))
            withAnimation(.spring(response: 0.34, dampingFraction: 0.55)) { done = true }
        }
    }
}

/// A thin red ring with the seconds left inside, draining as they go; then a red disc with a tick.
private struct CountdownRing: View {
    let left: Double
    let done: Bool

    var body: some View {
        ZStack {
            if done {
                Circle().fill(YYColor.danger)
                    .overlay {
                        Image(systemName: "checkmark")
                            .font(.yy(size: 13, weight: .heavy))
                            .foregroundStyle(.white)
                    }
                    .transition(.scale(scale: 0.4).combined(with: .opacity))
            } else {
                Circle().stroke(YYColor.danger.opacity(0.18), lineWidth: 2.2 * 1.2)
                // Drains anticlockwise from the top, as Telegram's does.
                Circle().trim(from: 1 - left, to: 1)
                    .stroke(YYColor.danger, style: StrokeStyle(lineWidth: 2.2 * 1.2, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                Text("\(max(1, Int((left * Library.undoSeconds).rounded(.up))))")
                    .font(.yy(size: 11.5 * 1.2, weight: .bold).monospacedDigit())
                    .foregroundStyle(YYColor.danger)
                    .contentTransition(.numericText(countsDown: true))
                    .animation(.snappy(duration: 0.28), value: Int((left * Library.undoSeconds).rounded(.up)))
            }
        }
        .padding(1.2)
    }
}
