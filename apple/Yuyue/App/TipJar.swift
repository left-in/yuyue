import StoreKit
import SwiftUI

/// 请开发者喝咖啡: three one-off tips that unlock nothing. Consumables, so the same one can be
/// given again; nothing is remembered but a thank-you for this session.
@Observable
final class TipJar {
    static let ids = ["app.yuyue.tip.small", "app.yuyue.tip.medium", "app.yuyue.tip.large"]
    /// Shown until the store answers, and when it can't (no products set up yet).
    static let fallback = ["¥6", "¥18", "¥45"]

    private(set) var products: [Product] = []
    private(set) var buying: String?
    private(set) var thanked = false
    var problem: String?

    func load() async {
        guard products.isEmpty else { return }
        let found = (try? await Product.products(for: Self.ids)) ?? []
        products = found.sorted { $0.price < $1.price }
    }

    func buy(_ product: Product) async {
        buying = product.id
        problem = nil
        defer { buying = nil }
        do {
            switch try await product.purchase() {
            case .success(let result):
                if case .verified(let transaction) = result {
                    await transaction.finish()
                    thanked = true
                }
            case .pending:
                problem = String(localized: "等确认后就完成了")
            default:
                break
            }
        } catch {
            problem = Library.message(for: error)
        }
    }
}

/// `.v-me-cof`: the cup, what a tip does (nothing), three amounts, paid once.
struct TipCard: View {
    @State private var jar = TipJar()

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: YYUI.s(10)) {
                Image(systemName: "cup.and.saucer")
                    .font(YYUI.font(13, .medium))
                    .foregroundStyle(YYColor.t1)
                    .frame(width: YYUI.s(30), height: YYUI.s(30))
                    .background(YYColor.inset, in: .rect(cornerRadius: YYUI.s(8)))
                VStack(alignment: .leading, spacing: YYUI.s(1)) {
                    Text(jar.thanked ? String(localized: "谢谢你的咖啡") : String(localized: "请开发者喝咖啡")).font(YYUI.font(12, .semibold)).foregroundStyle(YYColor.t1)
                    Text(jar.thanked ? String(localized: "收到了。语阅会一直免费下去。") : String(localized: "不解锁任何功能，给不给用起来都一样。"))
                        .font(YYUI.font(10)).foregroundStyle(YYColor.t3)
                }
                Spacer(minLength: 0)
            }
            HStack(spacing: YYUI.s(8)) {
                if jar.products.isEmpty {
                    ForEach(TipJar.fallback, id: \.self) { price in tile(price, busy: false) {}.disabled(true) }
                } else {
                    ForEach(jar.products, id: \.id) { p in
                        tile(p.displayPrice, busy: jar.buying == p.id) { Task { await jar.buy(p) } }
                            .disabled(jar.buying != nil)
                    }
                }
            }
            .padding(.top, YYUI.s(12))
            Text(jar.problem ?? (jar.products.isEmpty ? String(localized: "上架之后就能付了。") : String(localized: "一次性付款，不会自动续费。")))
                .font(YYUI.font(10)).foregroundStyle(jar.problem == nil ? YYColor.t3 : YYColor.danger)
                .padding(.top, YYUI.s(9))
        }
        .padding(.top, YYUI.s(13))
        .padding(.bottom, YYUI.s(11))
        .padding(.horizontal, YYUI.s(13))
        .yyCard()
        .task { await jar.load() }
    }

    private func tile(_ price: String, busy: Bool, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            ZStack {
                Text(price).font(YYUI.font(14, .bold).monospacedDigit()).foregroundStyle(YYColor.t1).opacity(busy ? 0 : 1)
                if busy { ProgressView().controlSize(.small) }
            }
            .frame(maxWidth: .infinity)
            .frame(height: YYUI.s(42))
            .background(YYColor.inset, in: .rect(cornerRadius: YYUI.s(12)))
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
    }
}
