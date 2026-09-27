import SwiftUI
import AppKit

struct WorkshopView: View {
    @EnvironmentObject private var workshop: WorkshopModel
    @Environment(\.locale) private var locale
    @State private var password = ""
    @State private var guardCode = ""
    @State private var invalidGuard = false
    @FocusState private var guardFocused: Bool
    let showLibrary: () -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                VStack(alignment: .leading, spacing: 10) {
                    Text("从创意工坊添加").font(.title2.weight(.semibold))
                    Text("粘贴 Wallpaper Engine 创意工坊链接或项目 ID。下载完成后会自动加入全部壁纸。")
                        .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: 10) {
                        TextField("创意工坊链接或 ID", text: $workshop.link)
                            .textFieldStyle(.roundedBorder).onSubmit { workshop.lookup() }
                            .disabled(workshop.busy).accessibilityIdentifier("workshop.link")
                        Button("查看详情") { workshop.lookup() }
                            .disabled(workshop.busy || workshop.link.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                            .accessibilityIdentifier("workshop.lookup")
                    }
                }
                if workshop.activity == .lookup { ProgressView("正在读取项目…").controlSize(.small) }
                if let item = workshop.item { details(item) }
                if let error = workshop.error {
                    Label(AppStrings.text(error, locale: locale), systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("workshop.error")
                }
                componentSection
                if workshop.busy {
                    HStack {
                        if workshop.cancelling { ProgressView("正在取消…").controlSize(.small) }
                        Spacer()
                        Button("取消任务") { workshop.cancel() }.disabled(workshop.cancelling)
                    }
                }
            }.padding(28).frame(maxWidth: 740)
                .frame(maxWidth: .infinity, alignment: .top)
        }
        .onAppear { workshop.refreshComponent() }
        .onDisappear { password = ""; guardCode = "" }
        .onChange(of: workshop.waitingForGuard) { _, waiting in
            invalidGuard = false; guardCode = ""; guardFocused = waiting
        }
        .onChange(of: workshop.busy) { _, busy in if !busy { password = ""; guardCode = "" } }
    }

    private func details(_ item: WorkshopItem) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .top, spacing: 18) {
                AsyncImage(url: item.previewURL) { image in
                    image.resizable().scaledToFill()
                } placeholder: { Rectangle().fill(.quaternary).overlay { Image(systemName: "photo").foregroundStyle(.secondary) } }
                    .frame(width: 192, height: 108).clipped().clipShape(RoundedRectangle(cornerRadius: 10))
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 8) {
                    Text(item.title).font(.headline).lineLimit(3).textSelection(.enabled)
                    Text("ID " + item.id).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                    if item.bytes > 0 { Text(ByteCountFormatter.string(fromByteCount: item.bytes, countStyle: .file)).font(.caption).foregroundStyle(.secondary) }
                    Link("在 Steam 中查看", destination: item.communityURL)
                }
                Spacer(minLength: 0)
            }
            Divider()
            if let imported = workshop.importedURL {
                Label("已加入资料库", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                HStack {
                    Button("查看全部壁纸", action: showLibrary).buttonStyle(.borderedProminent)
                    Button("在访达中显示") { NSWorkspace.shared.activateFileViewerSelecting([imported]) }
                }
            } else {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Steam 账号").font(.headline)
                    Text("使用拥有 Wallpaper Engine 的账号。密码仅用于本次登录，不在应用中保存。")
                        .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    HStack {
                        TextField("Steam 登录账号", text: $workshop.account).textContentType(.username)
                            .accessibilityIdentifier("workshop.account")
                        SecureField("密码（已登录时可留空）", text: $password).textContentType(.password)
                            .accessibilityIdentifier("workshop.password")
                    }.textFieldStyle(.roundedBorder).disabled(workshop.busy)
                    if workshop.waitingForGuard {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("输入 Steam Guard 邮件或验证器中的代码。")
                            HStack {
                                SecureField("Steam Guard 验证码", text: $guardCode).textFieldStyle(.roundedBorder)
                                    .focused($guardFocused).onSubmit(submitGuard)
                                    .accessibilityIdentifier("workshop.guard")
                                Button("验证", action: submitGuard).disabled(guardCode.isEmpty)
                            }
                            if invalidGuard { Text("请输入 4-10 位字母或数字验证码。").foregroundStyle(.orange).font(.caption) }
                        }
                    }
                    downloadStatus
                    Button("下载并加入资料库") {
                        workshop.download(password: password); password = ""
                    }.buttonStyle(.borderedProminent)
                        .disabled(workshop.busy || workshop.component == nil || workshop.account.isEmpty)
                        .accessibilityIdentifier("workshop.download")
                }
            }
        }.padding(20).background(.background, in: RoundedRectangle(cornerRadius: 14))
            .overlay { RoundedRectangle(cornerRadius: 14).strokeBorder(.quaternary) }
    }

    @ViewBuilder private var downloadStatus: some View {
        if workshop.activity == .importing { ProgressView("正在校验并加入资料库…").controlSize(.small) }
        else if workshop.activity == .download {
            switch workshop.event {
            case .preparing: ProgressView("正在启动下载组件…").controlSize(.small)
            case .signingIn: ProgressView("正在登录 Steam…").controlSize(.small)
            case .guardCode: EmptyView()
            case .mobileApproval: Label("请在手机 Steam 中确认登录。", systemImage: "iphone")
            case .downloading(let progress):
                VStack(alignment: .leading, spacing: 6) {
                    if let progress { ProgressView(value: progress); Text(progress, format: .percent.precision(.fractionLength(0))).font(.caption).monospacedDigit() }
                    else { ProgressView("正在下载素材…").controlSize(.small) }
                }
            }
        }
    }

    private var componentSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("下载组件").font(.headline)
                Spacer()
                if workshop.component != nil { Label("已就绪", systemImage: "checkmark.circle").font(.caption).foregroundStyle(.secondary) }
            }
            if let component = workshop.component {
                Text(component.path).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
            } else {
                Text("首次下载需要 SteamCMD。组件从 Valve 获取并校验，Apple 芯片 Mac 可能需要 Rosetta。")
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                if workshop.component == nil {
                    Button("准备下载组件") { workshop.installComponent() }.disabled(workshop.busy)
                        .accessibilityIdentifier("workshop.install")
                }
                Button("选择已有组件…", action: chooseComponent).disabled(workshop.busy)
                if workshop.activity == .component { ProgressView("正在准备…").controlSize(.small) }
            }
        }
    }
    private func submitGuard() {
        if workshop.submitGuard(guardCode) { guardCode = ""; invalidGuard = false }
        else { invalidGuard = true }
    }
    private func chooseComponent() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false; panel.allowsMultipleSelection = false
        panel.message = AppStrings.text("选择官方 SteamCMD 可执行文件（steamcmd）。", locale: locale)
        if panel.runModal() == .OK, let url = panel.url { workshop.selectComponent(url) }
    }
}
