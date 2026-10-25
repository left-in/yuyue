#if os(iOS)
import SwiftUI
import UniformTypeIdentifiers
import YuyueCore

/// 数据快照 (prototype 29): choose what goes in — the size written out as you choose — make
/// one, bring one back, export the reading record, and the ones made before, each to share.
struct PhoneSnapshot: View {
    let library: Library
    @State private var snapshots: Snapshots
    @State private var picking = false
    @State private var exporting = false
    @State private var importing: Importing?

    struct Importing: Identifiable {
        let url: URL
        let info: SnapshotInfo
        var id: URL { url }
    }

    init(library: Library) {
        self.library = library
        _snapshots = State(initialValue: Snapshots(library: library))
    }

    var body: some View {
        YYPage {
            Text("把进度、笔记、生词和设置打包成一个文件。换手机、换到 Android，都用它搬家。")
                .font(YYUI.font(10.5)).lineSpacing(YYUI.s(4)).foregroundStyle(YYColor.t2)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, YYUI.s(4))
                .padding(.top, YYUI.s(10))
                .padding(.bottom, YYUI.s(18))
            groupLabel(String(localized: "生成快照"))
            makeCard.padding(.bottom, YYUI.s(10))
            YYGroup {
                Button { picking = true } label: { YYRow(String(localized: "导入快照"), icon: "square.and.arrow.down", chevron: true) }
                    .buttonStyle(.plain)
                Button { exporting = true } label: {
                    YYRow(String(localized: "导出阅读记录"), icon: "square.and.arrow.up", value: "Goodreads、StoryGraph", chevron: true)
                }
                .buttonStyle(.plain)
            }
            .padding(.bottom, YYUI.s(18))
            if !snapshots.saved.isEmpty {
                groupLabel(String(localized: "以前的快照"))
                YYGroup {
                    ForEach(snapshots.saved) { s in savedRow(s) }
                }
                YYNote(String(localized: "快照存在“文件”App 的“语阅”文件夹里。"))
            }
        }
        .navigationTitle("数据快照")
        .navigationBarTitleDisplayMode(.inline)
        .task { await snapshots.load() }
        .fileImporter(isPresented: $picking, allowedContentTypes: [.yuyueSnapshot, .data]) { result in
            guard case .success(let url) = result else { return }
            open(url)
        }
        .sheet(isPresented: $exporting) { ReadingExportSheet(library: library) }
        .sheet(item: $importing) { SnapshotImportSheet(snapshots: snapshots, url: $0.url, info: $0.info) }
    }

    private func groupLabel(_ text: String) -> some View {
        Text(text).font(YYUI.font(10)).foregroundStyle(YYColor.t3)
            .padding(.horizontal, YYUI.s(4)).padding(.bottom, YYUI.s(6))
    }

    /// `.v-dt-mk`: a switch for each kind with how many there are, then the size and 生成快照.
    private var makeCard: some View {
        let c = snapshots.counts
        return YYGroup {
            part(String(localized: "进度和书签"), c.map { String(localized: "\(Snapshots.number($0.read)) 本") }, \.progress)
            part(String(localized: "笔记"), c.map { String(localized: "\(Snapshots.number($0.notes)) 条") }, \.notes)
            part(String(localized: "生词"), c.map { String(localized: "\(Snapshots.number($0.words)) 个") }, \.words)
            part(String(localized: "设置和替换规则"), nil, \.settings)
            part(String(localized: "书文件"), c.map { Snapshots.size($0.fileBytes) }, \.files)
            HStack(spacing: YYUI.s(8)) {
                (Text(snapshots.parts.files ? String(localized: "含书文件 · 约 ") : String(localized: "不含书文件 · 约 "))
                    + Text(c == nil ? "…" : PhoneStorage.size(snapshots.estimate)).fontWeight(.semibold).foregroundStyle(YYColor.t1))
                    .font(YYUI.font(10.5).monospacedDigit()).foregroundStyle(YYColor.t3)
                Spacer(minLength: 0)
                Button {
                    Task { await snapshots.make() }
                } label: {
                    if snapshots.making { ProgressView().controlSize(.small) } else { Text("生成快照") }
                }
                .buttonStyle(YYButtonStyle(kind: .main))
                .disabled(snapshots.making || !anyPart)
            }
            .padding(.vertical, YYUI.s(9))
            if let problem = snapshots.problem {
                Label(problem, systemImage: "exclamationmark.circle").font(YYUI.font(11)).foregroundStyle(YYColor.danger)
                    .frame(minHeight: YYUI.s(38))
            }
        }
    }

    private var anyPart: Bool {
        let p = snapshots.parts
        return p.progress || p.notes || p.words || p.settings || p.files
    }

    private func part(_ title: String, _ value: String?, _ key: WritableKeyPath<SnapshotParts, Bool>) -> some View {
        YYRow(title: title, value: value) {
            YYSwitch(isOn: Binding { snapshots.parts[keyPath: key] } set: { snapshots.parts[keyPath: key] = $0 }, label: title)
        }
    }

    /// `.v-dt-old`: when, from where, how big, and a button to send it on.
    private func savedRow(_ s: Snapshots.Saved) -> some View {
        HStack(spacing: YYUI.s(10)) {
            Button { open(s.url) } label: {
                VStack(alignment: .leading, spacing: YYUI.s(2)) {
                    Text(Snapshots.when(s.about.madeAt)).font(YYUI.font(11.5, .medium).monospacedDigit()).foregroundStyle(YYColor.t1)
                    Text(([Snapshots.from(s.about)] + (s.about.parts.files ? [String(localized: "含书文件")] : []) + [Snapshots.size(s.about.bytes)]).joined(separator: " · "))
                        .font(YYUI.font(10).monospacedDigit()).foregroundStyle(YYColor.t3).lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            ShareLink(item: s.url) {
                Image(systemName: "square.and.arrow.up").font(YYUI.font(11, .medium)).foregroundStyle(YYColor.t1)
                    .frame(width: YYUI.s(28), height: YYUI.s(28))
                    .background(YYColor.inset, in: .circle)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("分享")
        }
        .padding(.vertical, YYUI.s(9))
        .contextMenu {
            Button("导入这份", systemImage: "square.and.arrow.down") { open(s.url) }
            Button("删除", systemImage: "trash", role: .destructive) { snapshots.delete(s) }
        }
    }

    private func open(_ url: URL) {
        do {
            let (local, info) = try snapshots.preview(url)
            importing = Importing(url: local, info: info)
        } catch {
            library.alert = Library.message(for: error)
        }
    }
}
#endif
