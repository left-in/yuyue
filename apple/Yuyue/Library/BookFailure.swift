import SwiftUI

/// 这本书打不开: in place of a book or PDF that could not be opened at all — why, in a
/// sentence, and the way back to the shelf. A failure after the book is open (a mark not saved…)
/// is still the passing 出错了 alert.
struct BookFailureView: View {
    let reason: String
    let close: () -> Void

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "book.closed")
                .font(.yy(size: 34, weight: .light))
                .foregroundStyle(YYColor.t3)
            Text("这本书打不开")
                .font(.yy(size: 17, weight: .semibold))
                .foregroundStyle(YYColor.t1)
            Text(reason)
                .font(.yy(size: 13))
                .foregroundStyle(YYColor.t2)
                .multilineTextAlignment(.center)
                .lineSpacing(3)
                .frame(maxWidth: 300)
            Button(action: close) {
                Text("回到书架")
                    .font(.yy(size: 14, weight: .semibold))
                    .foregroundStyle(YYTint.standard.onBlack)
                    .padding(.horizontal, 22)
                    .frame(height: 40)
                    .background(YYTint.standard.black, in: .capsule)
                    .contentShape(.capsule)
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.cancelAction)
            .padding(.top, 6)
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(YYColor.bg)
        .accessibilityElement(children: .contain)
    }
}

extension View {
    /// The book could not be `opened`: 这本书打不开 over everything. Opened: `failure` as the
    /// passing 出错了 alert.
    func bookFailure(_ failure: Binding<String?>, opened: Bool) -> some View {
        modifier(BookFailureModifier(failure: failure, opened: opened))
    }
}

private struct BookFailureModifier: ViewModifier {
    @Binding var failure: String?
    let opened: Bool
    @Environment(\.dismiss) private var dismiss

    func body(content: Content) -> some View {
        if !opened {
            BookFailureView(reason: failure ?? String(localized: "这本书读不出来，文件可能坏了")) { dismiss() }
        } else {
            content
                .alert("出错了", isPresented: Binding(get: { failure != nil }, set: { if !$0 { failure = nil } })) {
                    Button("好") {}
                } message: {
                    Text(failure ?? "")
                }
        }
    }
}
