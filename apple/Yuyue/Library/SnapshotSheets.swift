import SwiftUI
import YuyueCore

/// 导入快照 (prototype 29): whose snapshot and when, what's in it, 合并 or 覆盖, and what the
/// library comes to after, before anything is done.
struct SnapshotImportSheet: View {
    let snapshots: Snapshots
    let url: URL
    let info: SnapshotInfo
    @State private var replace = false
    @State private var working = false
    @State private var problem: String?
    @Environment(\.dismiss) private var dismiss
    private let tint = YYTint.standard

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            YYSheetHeader(title: String(localized: "导入快照")) { dismiss() }
                .padding(.bottom, YYUI.s(12))
            fileCard
            HStack(spacing: YYUI.s(8)) {
                choice(false, String(localized: "合并"), String(localized: "这台设备上的都留着，加上快照里没有的；同一条取较新的。"))
                choice(true, String(localized: "覆盖"), String(localized: "这台设备上的全部换成快照里的。换之前先自动备份一份。"))
            }
            .padding(.top, YYUI.s(10))
            Text(problem ?? Snapshots.change(info, replace: replace))
                .font(YYUI.font(10.5).monospacedDigit())
                .foregroundStyle(problem == nil ? YYColor.t2 : YYColor.danger)
                .frame(maxWidth: .infinity)
                .multilineTextAlignment(.center)
                .padding(.top, YYUI.s(12))
            Button {
                Task { await bringBack() }
            } label: {
                if working { ProgressView().controlSize(.small).tint(tint.onBlack) } else { Text("导入") }
            }
            .buttonStyle(YYButtonStyle(kind: .main, size: .large, wide: true))
            .disabled(working)
            .padding(.top, YYUI.s(12))
        }
        .padding(YYUI.s(16))
        #if os(macOS)
        .frame(width: 400)
        #else
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        #endif
        .background(YYColor.bg)
    }

    /// `.v-dt-file`: the file, where it's from, and what it holds.
    private var fileCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: YYUI.s(10)) {
                Image(systemName: "shippingbox").font(YYUI.font(13)).foregroundStyle(YYColor.t1)
                    .frame(width: YYUI.s(30), height: YYUI.s(30))
                    .background(YYColor.inset, in: .rect(cornerRadius: YYUI.s(8)))
                VStack(alignment: .leading, spacing: YYUI.s(2)) {
                    Text(url.lastPathComponent).font(YYUI.font(11.5, .semibold)).foregroundStyle(YYColor.t1).lineLimit(1).truncationMode(.middle)
                    Text("来自\(Snapshots.from(info.deviceName).hasPrefix("这台") ? "" : " ")\(Snapshots.from(info.deviceName)) · \(Snapshots.when(info.madeAt)) · \(Snapshots.size(info.bytes))")
                        .font(YYUI.font(10).monospacedDigit()).foregroundStyle(YYColor.t3).lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .padding(.bottom, YYUI.s(10))
            Rectangle().fill(YYColor.line).frame(height: 0.5)
            FlowTags(tags: tags).padding(.top, YYUI.s(10))
        }
        .padding(YYUI.s(12))
        .yyCard()
    }

    private var tags: [(String, String?)] {
        var out: [(String, String?)] = []
        let c = info.counts
        if info.parts.progress { out.append((String(localized: "进度"), String(localized: "\(Snapshots.number(c.read)) 本"))) }
        if info.parts.notes { out.append((String(localized: "笔记"), String(localized: "\(Snapshots.number(c.notes)) 条"))) }
        if info.parts.words { out.append((String(localized: "生词"), String(localized: "\(Snapshots.number(c.words)) 个"))) }
        if info.parts.settings { out.append((String(localized: "设置"), nil)) }
        if info.parts.files { out.append((String(localized: "书文件"), Snapshots.size(c.fileBytes))) }
        return out
    }

    /// `.v-dt-mode`: one of the two ways, ringed and ticked when chosen.
    private func choice(_ value: Bool, _ title: String, _ detail: String) -> some View {
        let on = replace == value
        return Button { replace = value } label: {
            VStack(alignment: .leading, spacing: YYUI.s(6)) {
                HStack {
                    Text(title).font(YYUI.font(12.5, .semibold)).foregroundStyle(YYColor.t1)
                    Spacer(minLength: 0)
                    if on { Image(systemName: "checkmark").font(YYUI.font(11, .semibold)).foregroundStyle(tint.accent) }
                }
                Text(detail).font(YYUI.font(10)).lineSpacing(YYUI.s(3)).foregroundStyle(YYColor.t2)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
            .padding(YYUI.s(12))
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(YYColor.card, in: .rect(cornerRadius: YYUI.s(14)))
            .overlay(RoundedRectangle(cornerRadius: YYUI.s(14)).strokeBorder(on ? YYColor.t1 : YYColor.line, lineWidth: on ? 1.5 : 0.5))
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(on ? .isSelected : [])
    }

    private func bringBack() async {
        working = true
        problem = nil
        do {
            try await snapshots.restore(url, replace: replace)
            dismiss()
        } catch {
            problem = Library.message(for: error)
        }
        working = false
    }
}

/// Grey tags with a bold number, wrapping onto more lines when they must.
private struct FlowTags: View {
    let tags: [(String, String?)]

    var body: some View {
        Flow(spacing: YYUI.s(6)) {
            ForEach(tags, id: \.0) { name, value in
                HStack(spacing: YYUI.s(4)) {
                    Text(name).foregroundStyle(YYColor.t2)
                    if let value { Text(value).fontWeight(.semibold).foregroundStyle(YYColor.t1) }
                }
                .font(YYUI.font(10).monospacedDigit())
                .padding(.horizontal, YYUI.s(7))
                .padding(.vertical, YYUI.s(4))
                .background(YYColor.inset, in: .rect(cornerRadius: YYUI.s(6)))
            }
        }
    }
}

/// Lays its children in rows, left to right, starting a new row when one is full.
struct Flow: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = rows(subviews, width: proposal.width ?? .infinity)
        let width = rows.map { $0.width }.max() ?? 0
        let height = rows.reduce(0) { $0 + $1.height } + spacing * CGFloat(max(0, rows.count - 1))
        return CGSize(width: width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in rows(subviews, width: bounds.width) {
            var x = bounds.minX
            for i in row.items {
                let size = subviews[i].sizeThatFits(.unspecified)
                subviews[i].place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
            y += row.height + spacing
        }
    }

    private struct Row { var items: [Int] = []; var width: CGFloat = 0; var height: CGFloat = 0 }

    private func rows(_ subviews: Subviews, width: CGFloat) -> [Row] {
        var rows: [Row] = [Row()]
        for (i, view) in subviews.enumerated() {
            let size = view.sizeThatFits(.unspecified)
            if !rows[rows.count - 1].items.isEmpty, rows[rows.count - 1].width + spacing + size.width > width {
                rows.append(Row())
            }
            var row = rows[rows.count - 1]
            row.width += (row.items.isEmpty ? 0 : spacing) + size.width
            row.height = max(row.height, size.height)
            row.items.append(i)
            rows[rows.count - 1] = row
        }
        return rows
    }
}

/// 导出阅读记录 (prototype 29): the shelf as a CSV for Goodreads or StoryGraph — how many of
/// each, the first lines of the file, and a word on the books without an ISBN.
struct ReadingExportSheet: View {
    let library: Library
    @State private var site = ReadingSite.goodreads
    @State private var export: ReadingExport?
    @State private var file: URL?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            YYSheetHeader(title: String(localized: "导出阅读记录")) { dismiss() }
                .padding(.bottom, YYUI.s(12))
            YYSegments(items: [(ReadingSite.goodreads, "Goodreads"), (.storyGraph, "StoryGraph")], selection: $site)
            YYGroup {
                YYRow(String(localized: "想读"), icon: "bookmark", value: String(localized: "\(export?.want ?? 0) 本"))
                YYRow(String(localized: "在读"), icon: "book", value: String(localized: "\(export?.reading ?? 0) 本"))
                YYRow(String(localized: "读完"), icon: "checkmark.circle", value: String(localized: "\(export?.finished ?? 0) 本 · 带读完日期"))
            }
            .padding(.top, YYUI.s(10))
            preview.padding(.top, YYUI.s(14))
            if let export, export.withoutIsbn > 0 {
                YYNote(String(localized: "没有 ISBN 的 \(export.withoutIsbn) 本按书名和作者对，导进去后可能要在网站上确认一下。"))
            }
            Spacer(minLength: YYUI.s(14))
            if let file, let export {
                ShareLink(item: file) {
                    Text("导出 \(export.want + export.reading + export.finished) 本 · CSV")
                }
                .buttonStyle(YYButtonStyle(kind: .main, size: .large, wide: true))
            } else {
                Button("导出 · CSV") {}.buttonStyle(YYButtonStyle(kind: .main, size: .large, wide: true)).disabled(true)
            }
        }
        .padding(YYUI.s(16))
        #if os(macOS)
        .frame(width: 400, height: 470)
        #else
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
        #endif
        .background(YYColor.bg)
        .task(id: site) { make() }
    }

    /// `.v-csv`: the header line and the first few rows, as the file has them.
    private var preview: some View {
        let lines = (export?.csv ?? "").split(separator: "\n").prefix(4).map(String.init)
        return VStack(alignment: .leading, spacing: YYUI.s(3)) {
            ForEach(Array(lines.enumerated()), id: \.offset) { i, line in
                Text(line)
                    .font(.system(size: YYUI.s(9.5), weight: i == 0 ? .bold : .regular, design: .monospaced))
                    .foregroundStyle(i == 0 ? YYColor.t1 : YYColor.t2)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
        }
        .padding(YYUI.s(12))
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(YYColor.inset, in: .rect(cornerRadius: YYUI.s(10)))
    }

    private func make() {
        let offset = Int32(TimeZone.current.secondsFromGMT() / 60)
        guard let made = try? library.core.readingExport(site: site, utcOffsetMinutes: offset) else { return }
        export = made
        let name = site == .goodreads ? String(localized: "语阅-goodreads.csv") : String(localized: "语阅-storygraph.csv")
        let url = FileManager.default.temporaryDirectory.appending(path: name)
        file = (try? Data(made.csv.utf8).write(to: url)).map { url }
    }
}

/// A snapshot opened from outside (文件, Finder, a drop) gets the same look before anything is done.
private struct OpeningSnapshots: ViewModifier {
    let library: Library
    @State private var shown: Shown?

    struct Shown: Identifiable {
        let snapshots: Snapshots
        let url: URL
        let info: SnapshotInfo
        var id: URL { url }
    }

    func body(content: Content) -> some View {
        content
            .onChange(of: library.openedSnapshot) { _, url in
                guard let url else { return }
                library.openedSnapshot = nil
                let snapshots = Snapshots(library: library)
                do {
                    let (local, info) = try snapshots.preview(url)
                    shown = Shown(snapshots: snapshots, url: local, info: info)
                } catch {
                    library.alert = Library.message(for: error)
                }
            }
            .sheet(item: $shown) { SnapshotImportSheet(snapshots: $0.snapshots, url: $0.url, info: $0.info) }
    }
}

extension View {
    func openingSnapshots(_ library: Library) -> some View { modifier(OpeningSnapshots(library: library)) }
}
