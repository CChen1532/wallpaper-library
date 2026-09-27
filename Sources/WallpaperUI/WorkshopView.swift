import SwiftUI
import AppKit

struct WorkshopView: View {
    @EnvironmentObject private var workshop: WorkshopModel
    @EnvironmentObject private var model: LibraryModel
    @Environment(\.locale) private var locale
    @State private var password = ""
    @State private var guardCode = ""
    @State private var invalidGuard = false
    @State private var tab = 0
    @State private var showSubscriptions = false
    @StateObject private var subscriptionBrowser = WorkshopSubscriptionBrowser()
    @FocusState private var guardFocused: Bool
    let showLibrary: () -> Void

    var body: some View {
        ScrollViewReader { proxy in
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                Text("创意工坊").font(.title2.weight(.semibold)).id("workshopTop")
                Picker("浏览方式", selection: $tab) {
                    Text("全文搜索").tag(0)
                    Text("链接或 ID").tag(1)
                    Text("订阅同步").tag(2)
                }.pickerStyle(.segmented).disabled(workshop.busy)
                if tab == 0 {
                    HStack {
                        TextField("搜索标题与描述", text: $workshop.searchText).textFieldStyle(.roundedBorder)
                            .onSubmit { workshop.search() }.disabled(workshop.busy)
                            .accessibilityIdentifier("workshop.searchText")
                        Button("搜索") { workshop.search() }.disabled(workshop.busy || !workshop.filters.validDates)
                            .accessibilityIdentifier("workshop.search")
                    }
                    browseFilters
                    if workshop.activity == .search { ProgressView("正在搜索…").controlSize(.small) }
                } else if tab == 1 {
                    HStack(spacing: 10) {
                        TextField("创意工坊链接或 ID", text: $workshop.link)
                            .textFieldStyle(.roundedBorder).onSubmit { workshop.lookup() }
                            .disabled(workshop.busy).accessibilityIdentifier("workshop.link")
                        Button("查看详情") { workshop.lookup() }
                            .disabled(workshop.busy || workshop.link.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                            .accessibilityIdentifier("workshop.lookup")
                    }
                } else { subscriptionSection }
                if workshop.activity == .lookup { ProgressView("正在读取项目…").controlSize(.small) }
                if tab != 2, let item = workshop.item { details(item).id("selectedWorkshop") }
                if tab == 0, let page = workshop.searchPage {
                    HStack {
                        Text(page.candidateCount
                             ? String(format: AppStrings.text("本页符合条件 %d 项", locale: locale), page.items.count)
                             : String(format: AppStrings.text("共 %d 项", locale: locale), page.total))
                            .font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        Button("上一页") { workshop.search(page: page.number - 1) }.disabled(workshop.busy || page.number <= 1)
                        Text("\(page.number) / \(max(1, page.pages))").font(.caption).monospacedDigit()
                        Button("下一页") { workshop.search(page: page.number + 1) }.disabled(workshop.busy || page.number >= page.pages)
                    }
                    if page.items.isEmpty {
                        ContentUnavailableView("没有找到壁纸", systemImage: "magnifyingglass",
                            description: Text(page.candidateCount && page.number < page.pages
                                ? "本页没有符合条件的壁纸，可以继续下一页。" : "试试其他关键词或放宽筛选条件。"))
                    }
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 180, maximum: 230), spacing: 16)], spacing: 16) {
                        ForEach(page.items) { item in
                            Button {
                                workshop.select(item)
                            } label: {
                                VStack(alignment: .leading, spacing: 8) {
                                    AsyncImage(url: item.previewURL) { image in image.resizable().scaledToFill() }
                                        placeholder: { Rectangle().fill(.quaternary) }
                                        .frame(height: 112).clipped()
                                    Text(item.title).font(.callout.weight(.medium)).lineLimit(2).frame(height: 36, alignment: .topLeading)
                                        .padding(.horizontal, 10)
                                    Text(classification(item)).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                        .padding(.horizontal, 10).padding(.bottom, 10)
                                }.frame(maxWidth: .infinity, alignment: .leading)
                                    .background(.background, in: RoundedRectangle(cornerRadius: 12))
                                    .clipShape(RoundedRectangle(cornerRadius: 12))
                                    .overlay { RoundedRectangle(cornerRadius: 12).strokeBorder(.quaternary) }
                            }.buttonStyle(.plain).modifier(HoverHighlight()).disabled(workshop.busy)
                        }
                    }
                }
                if let error = workshop.error {
                    Label(AppStrings.text(error, locale: locale), systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("workshop.error")
                }
                componentSection
            }.padding(28).frame(maxWidth: 900)
                .frame(maxWidth: .infinity, alignment: .top)
        }
        .onChange(of: workshop.item?.id) { _, id in if id != nil { proxy.scrollTo("selectedWorkshop", anchor: .top) } }
        .onChange(of: workshop.searchPage?.number) { _, _ in proxy.scrollTo("workshopTop", anchor: .top) }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if workshop.busy {
                HStack {
                    if workshop.cancelling { ProgressView("正在取消…").controlSize(.small) }
                    else { ProgressView().controlSize(.small) }
                    if workshop.syncing { Text(String(format: AppStrings.text("正在同步 %d / %d", locale: locale), workshop.syncPosition, workshop.syncTotal)).font(.caption) }
                    Spacer()
                    Button("取消任务") { workshop.cancel() }.disabled(workshop.cancelling)
                }.padding(12).background(.bar)
            }
        }
        .sheet(isPresented: $showSubscriptions) {
            WorkshopSubscriptionSheet(browser: subscriptionBrowser) { workshop.receiveSubscriptions($0) }
        }
        .onAppear { workshop.refreshComponent() }
        .onDisappear { password = ""; guardCode = "" }
        .onChange(of: workshop.waitingForGuard) { _, waiting in
            invalidGuard = false; guardCode = ""; guardFocused = waiting
        }
        .onChange(of: workshop.busy) { _, busy in if !busy { password = ""; guardCode = "" } }
    }

    private func classification(_ item: WorkshopItem) -> String {
        WorkshopFilters.classification(tags: item.tags).map { AppStrings.text($0, locale: locale) }.joined(separator: " · ")
    }
    private func filterBinding<Value>(_ key: WritableKeyPath<WorkshopFilters, Value>, immediate: Bool = true) -> Binding<Value> {
        Binding(get: { workshop.filters[keyPath: key] }, set: { value in
            var next = workshop.filters; next[keyPath: key] = value
            workshop.setFilters(next, searchImmediately: immediate)
        })
    }
    private func filterPicker<Value: WorkshopFilterChoice>(_ title: String, key: WritableKeyPath<WorkshopFilters, Value>, id: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(AppStrings.text(title, locale: locale)).font(.caption).foregroundStyle(.secondary)
            Picker(LocalizedStringKey(title), selection: filterBinding(key)) {
                ForEach(Array(Value.allCases), id: \.self) { option in Text(LocalizedStringKey(option.label)).tag(option) }
            }.labelsHidden().accessibilityIdentifier(id)
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
    private var browseFilters: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 16) {
                WorkshopMultiChoiceFilter(title: "年龄分级", allLabel: "全部年龄", countLabel: "已选 %d 项分级",
                    hint: "同组任选其一，按作者在 Steam 标注的分级筛选。",
                    choices: WorkshopFilters.Age.allCases.filter { $0 != .all },
                    selection: filterBinding(\.ages), id: "workshop.age")
                WorkshopMultiChoiceFilter(title: "壁纸类型", allLabel: "全部类型", countLabel: "已选 %d 项类型",
                    hint: "场景、视频或网页，同组任选其一。",
                    choices: WorkshopFilters.Kind.allCases.filter { $0 != .all && $0 != .application },
                    selection: filterBinding(\.kinds), id: "workshop.kind")
                WorkshopMultiChoiceFilter(title: "内容题材", allLabel: "全部题材", countLabel: "已选 %d 项题材",
                    hint: "同时匹配所有勾选题材；不勾选表示不限。",
                    choices: WorkshopFilters.Genre.allCases.filter { $0 != .all },
                    selection: filterBinding(\.genres), id: "workshop.genre")
            }
            HStack(alignment: .bottom, spacing: 16) {
                filterPicker("排序方式", key: \.sort, id: "workshop.sort")
                filterPicker("发布日期", key: \.period, id: "workshop.period")
                Button("重置筛选") { workshop.setFilters(.init()) }
                    .disabled(workshop.filters.isDefault).frame(maxWidth: .infinity, alignment: .trailing)
                    .accessibilityIdentifier("workshop.resetFilters")
            }
            if workshop.filters.period == .custom {
                HStack(spacing: 16) {
                    DatePicker("开始日期", selection: filterBinding(\.startDate, immediate: false), in: Date(timeIntervalSince1970: 0)...Date(), displayedComponents: .date)
                        .accessibilityIdentifier("workshop.startDate")
                    DatePicker("结束日期", selection: filterBinding(\.endDate, immediate: false), in: Date(timeIntervalSince1970: 0)...Date(), displayedComponents: .date)
                        .accessibilityIdentifier("workshop.endDate")
                    Button("应用日期") { workshop.search() }.disabled(!workshop.filters.validDates)
                }
                if !workshop.filters.validDates {
                    Text("结束日期不能早于开始日期。").font(.caption).foregroundStyle(.red)
                }
            }
            if workshop.filters.browseSort(query: workshop.searchText.trimmingCharacters(in: .whitespacesAndNewlines)) == "trend" {
                Text("最热门按近 7 天热度排序；日期范围按作品发布时间筛选。").font(.caption).foregroundStyle(.secondary)
            }
            if workshop.filters.kinds.contains(.web) {
                Text("网页壁纸可浏览，暂不支持在此应用中播放。").font(.caption).foregroundStyle(.secondary)
            }
            if workshop.filters.needsLocalMatch {
                Text("同组多选按任一条件匹配；每页显示该页符合条件的项目，页数以 Steam 候选结果为准。")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }.disabled(workshop.busy)
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
                    Text(classification(item)).font(.caption).foregroundStyle(.secondary)
                    if item.bytes > 0 { Text(ByteCountFormatter.string(fromByteCount: item.bytes, countStyle: .file)).font(.caption).foregroundStyle(.secondary) }
                    Link("在 Steam 中查看", destination: item.communityURL)
                }
                Spacer(minLength: 0)
            }
            Divider()
            if let imported = workshop.importedURL {
                Label("已下载", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                HStack {
                    Button("加入并查看资料库") { Task { await workshop.registerImported(); showLibrary() } }.buttonStyle(.borderedProminent)
                    Button("在访达中显示") { NSWorkspace.shared.activateFileViewerSelecting([imported]) }
                }
            } else if !WorkshopFilters.supportsPlayback(tags: item.tags) {
                Text("网页和应用程序壁纸可浏览，暂不支持在此应用中播放。").foregroundStyle(.secondary)
            } else {
                VStack(alignment: .leading, spacing: 12) {
                    accountForm
                    Button("下载并加入资料库") {
                        workshop.download(password: password); password = ""
                    }.buttonStyle(.borderedProminent)
                        .disabled(workshop.busy || model.isWorking || workshop.component == nil || workshop.account.isEmpty)
                        .accessibilityIdentifier("workshop.download")
                }
            }
        }.padding(20).background(.background, in: RoundedRectangle(cornerRadius: 14))
            .overlay { RoundedRectangle(cornerRadius: 14).strokeBorder(.quaternary) }
    }

    private var accountForm: some View {
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
        }
    }

    private var subscriptionSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("读取当前 Steam 订阅，补齐本地缺少的场景与 MP4 视频。已有文件会保留；取消订阅不会删除本地壁纸。")
                .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack {
                Button("读取 Steam 订阅") {
                    showSubscriptions = true
                }.disabled(workshop.busy)
                    .accessibilityIdentifier("workshop.readSubscriptions")
                if let date = workshop.subscriptionReadAt { Text(date, style: .time).font(.caption).foregroundStyle(.secondary) }
                if workshop.activity == .subscriptions { ProgressView("正在读取项目…").controlSize(.small) }
            }
            if workshop.subscriptionReadAt != nil {
                Text(String(format: AppStrings.text("订阅 %d 项，可读取 %d 项", locale: locale), workshop.subscriptionCount, workshop.subscriptions.count)).font(.caption).foregroundStyle(.secondary)
                Text("已移除或不公开的项目可能无法读取。手动删除的壁纸会跳过；重新下载前可恢复同步。")
                    .font(.caption).foregroundStyle(.secondary)
                if workshop.ignoredCount > 0 {
                    Button("恢复已删除项目的同步") { workshop.restoreSyncItems() }.disabled(workshop.busy)
                }
                accountForm
                if workshop.syncing {
                    Text(String(format: AppStrings.text("正在同步 %d / %d", locale: locale), workshop.syncPosition, workshop.syncTotal)).font(.caption).monospacedDigit()
                    Text(workshop.downloadTitle).font(.callout).lineLimit(2)
                }
                Button("同步缺少的壁纸") { workshop.syncSubscriptions(password: password); password = "" }
                    .buttonStyle(.borderedProminent)
                    .disabled(workshop.busy || model.isWorking || workshop.component == nil || workshop.account.isEmpty || workshop.subscriptions.isEmpty)
                    .accessibilityIdentifier("workshop.syncSubscriptions")
                LazyVStack(spacing: 0) {
                    ForEach(workshop.subscriptions) { item in
                        HStack {
                            Text(item.title).lineLimit(2)
                            Spacer()
                            Text(AppStrings.text(workshop.subscriptionStatus(item), locale: locale)).font(.caption).foregroundStyle(.secondary)
                        }.padding(.vertical, 10)
                        Divider()
                    }
                }
            }
        }
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

private struct WorkshopMultiChoiceFilter<Choice: WorkshopFilterChoice>: View {
    @Environment(\.locale) private var locale
    let title: String
    let allLabel: String
    let countLabel: String
    let hint: String
    let choices: [Choice]
    @Binding var selection: Set<Choice>
    let id: String
    @State private var draft: Set<Choice> = []
    @State private var showing = false

    private var selected: [Choice] { choices.filter { selection.contains($0) } }
    private var summary: String {
        if selected.isEmpty { return AppStrings.text(allLabel, locale: locale) }
        if selected.count == 1 { return AppStrings.text(selected[0].label, locale: locale) }
        return String(format: AppStrings.text(countLabel, locale: locale), selected.count)
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(LocalizedStringKey(title)).font(.caption).foregroundStyle(.secondary)
            Button {
                draft = selection
                showing = true
            } label: {
                HStack {
                    Text(summary).lineLimit(1)
                    Spacer(minLength: 4)
                    Image(systemName: "chevron.down").font(.caption2).foregroundStyle(.secondary)
                }.frame(maxWidth: .infinity)
            }.buttonStyle(.bordered).controlSize(.regular)
                .accessibilityIdentifier(id)
                .accessibilityLabel(Text(LocalizedStringKey(title)))
                .accessibilityValue(Text(summary))
                .popover(isPresented: $showing, arrowEdge: .bottom) {
                    VStack(alignment: .leading, spacing: 14) {
                        Text(LocalizedStringKey(title)).font(.headline)
                        Text(LocalizedStringKey(hint)).font(.caption).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        ScrollView {
                            LazyVGrid(columns: [GridItem(.flexible(), alignment: .leading), GridItem(.flexible(), alignment: .leading)],
                                      alignment: .leading, spacing: 12) {
                                ForEach(choices, id: \.self) { choice in
                                    Toggle(LocalizedStringKey(choice.label), isOn: Binding(
                                        get: { draft.contains(choice) },
                                        set: { selected in if selected { draft.insert(choice) } else { draft.remove(choice) } }
                                    )).toggleStyle(.checkbox)
                                }
                            }.padding(2)
                        }.frame(maxHeight: 330)
                        Divider()
                        HStack {
                            Button("清空勾选") { draft = [] }.disabled(draft.isEmpty)
                            Spacer()
                            Button("取消") { showing = false }.keyboardShortcut(.cancelAction)
                            Button("应用") { showing = false; selection = draft }.keyboardShortcut(.defaultAction)
                        }
                    }.padding(18).frame(width: 350)
                }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
}
