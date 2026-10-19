#if os(iOS)
import SwiftUI

/// 笔记导出 under 我的: where 笔记 › 导出 › 发到 sends. Obsidian is a folder (the vault in
/// 文件, or one in it); Notion an integration's token and the page the books go under; flomo
/// its API link. Tokens stay in the keychain.
struct PhoneNoteExport: View {
    @State private var folder = NoteExport.obsidianFolder
    @State private var picking = false
    @State private var notionToken = Keychain.read(NoteExport.notionKey) ?? ""
    @AppStorage(NoteExport.notionPageKey) private var notionPage = ""
    @State private var flomo = Keychain.read(NoteExport.flomoKey) ?? ""

    var body: some View {
        YYPage {
            YYLabel("Obsidian")
            YYGroup {
                Button { picking = true } label: {
                    YYRow(String(localized: "文件夹"), icon: "folder", value: folder?.lastPathComponent ?? String(localized: "还没选"), chevron: true)
                }
                .buttonStyle(.plain)
            }
            YYNote(String(localized: "每本书一篇笔记，写进你选的文件夹；再发一次就更新那一篇。在“文件”里选 Obsidian 库，或库里的一个文件夹。"))

            YYLabel("Notion")
            YYGroup {
                YYField(label: String(localized: "令牌"), labelWidth: 44) {
                    SecureField("", text: $notionToken, prompt: Text(verbatim: "ntn_…"))
                        .font(YYUI.font(11.5, design: .monospaced))
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                        .onChange(of: notionToken) { save(NoteExport.notionKey, notionToken) }
                }
                YYField(label: String(localized: "页面"), labelWidth: 44) {
                    TextField("", text: $notionPage, prompt: Text(verbatim: "https://www.notion.so/…"))
                        .font(YYUI.font(11, design: .monospaced))
                        .keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                }
            }
            .foregroundStyle(YYColor.t1)
            YYNote(notionPage.isEmpty || NoteExport.pageID(from: notionPage) != nil
                   ? String(localized: "在 notion.so/my-integrations 建一个集成，令牌填在上面；再把要放书的页面共享给它，页面链接填在下面。每本书在它下面一页。")
                   : String(localized: "这不像一个 Notion 页面链接"))

            YYLabel("flomo")
            YYGroup {
                YYField(label: String(localized: "链接"), labelWidth: 44) {
                    SecureField("", text: $flomo, prompt: Text(verbatim: "https://flomoapp.com/iwh/…"))
                        .font(YYUI.font(11.5, design: .monospaced))
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                        .onChange(of: flomo) { save(NoteExport.flomoKey, flomo) }
                }
            }
            .foregroundStyle(YYColor.t1)
            YYNote(String(localized: "flomo 网页版 › 设置 › API，拷那条以 https://flomoapp.com/iwh/ 开头的链接；每条划线成一条笔记"))
        }
        .navigationTitle("笔记导出")
        .navigationBarTitleDisplayMode(.inline)
        .fileImporter(isPresented: $picking, allowedContentTypes: [.folder]) { result in
            guard case .success(let url) = result else { return }
            NoteExport.setObsidianFolder(url)
            folder = NoteExport.obsidianFolder
        }
    }

    private func save(_ key: String, _ value: String) {
        let v = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if v.isEmpty { Keychain.delete(key) } else { Keychain.write(key, v) }
    }
}
#endif
