import SwiftUI

struct LibraryBatchBar: View {
    @Environment(\.locale) private var locale
    let selectedCount: Int
    let hidden: Bool
    let canDelete: Bool
    let canRotate: Bool
    let busy: Bool
    let selectAll: () -> Void
    let clear: () -> Void
    let changeVisibility: () -> Void
    let remove: () -> Void
    let rotate: () -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(String(format: AppStrings.text("已选择 %d 项", locale: locale), selectedCount)).fontWeight(.medium)
                Button("全选当前结果", action: selectAll).buttonStyle(.link)
                Button("取消选择", action: clear).buttonStyle(.link).disabled(selectedCount == 0)
                Spacer()
            }
            HStack {
                Button(LocalizedStringKey(hidden ? "恢复显示" : "隐藏所选"), systemImage: hidden ? "eye" : "eye.slash", action: changeVisibility)
                    .disabled(selectedCount == 0).accessibilityIdentifier("library.batch.visibility")
                Button("加入轮播", systemImage: "arrow.triangle.2.circlepath", action: rotate)
                    .disabled(!canRotate).accessibilityIdentifier("library.batch.rotation")
                Spacer()
                Button("移入废纸篓…", systemImage: "trash", role: .destructive, action: remove)
                    .disabled(!canDelete).accessibilityIdentifier("library.batch.trash")
            }
            Text("点击卡片多选，Shift 点击可连续选择；选择仅限当前显示结果。")
                .font(.caption).foregroundStyle(.secondary)
        }.padding(.horizontal, 24).padding(.bottom, 12).disabled(busy)
    }
}

struct BatchTrashPreview: Identifiable {
    let id = UUID()
    let requests: [MaterialRemoval.Request]
    let skipped: Int
}

struct BatchTrashSheet: View {
    @Environment(\.locale) private var locale
    let requests: [MaterialRemoval.Request]
    let skipped: Int
    let cancel: () -> Void
    let confirm: () -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("批量移入废纸篓").font(.title2.bold())
            Text(String(format: AppStrings.text("将移除 %d 个项目，可从系统废纸篓恢复。", locale: locale), requests.count))
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(requests) { request in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(request.title).fontWeight(.medium)
                            Text(request.target.path).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                        }
                    }
                }.frame(maxWidth: .infinity, alignment: .leading).padding(10)
            }.frame(maxHeight: 220).background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
            Text("项目文件夹及素材会一并移动；受影响的播放会先停止。")
                .font(.callout).foregroundStyle(.secondary)
            if skipped > 0 {
                Text(String(format: AppStrings.text("已跳过 %d 项内置、重复或不可删除的壁纸。", locale: locale), skipped))
                    .font(.callout).foregroundStyle(.secondary)
            }
            HStack {
                Spacer()
                Button("取消", action: cancel).keyboardShortcut(.cancelAction)
                Button("移入废纸篓", role: .destructive, action: confirm)
                    .disabled(requests.isEmpty)
                    .accessibilityIdentifier("library.batch.confirmTrash")
            }
        }.padding(24).frame(width: 540)
    }
}

struct SelectionRotationView: View {
    @Environment(\.locale) private var locale
    @EnvironmentObject private var model: LibraryModel
    @ObservedObject var collection: LibraryCollectionStore
    @Binding var draft: RotationDraft
    let chooseWallpapers: () -> Void
    private var applied: Bool {
        model.selectionRotation.active && draft.matches(interval: collection.interval, mode: collection.mode)
    }
    var body: some View {
        Form {
            Section("所选壁纸轮播") {
                LabeledContent("当前状态", value: AppStrings.text(model.selectionRotation.active ? "已开启" : "已关闭", locale: locale))
                Text("仅轮播下方列表中的场景与视频；隐藏项会跳过。退出应用或系统睡眠时停止自动切换。")
                    .font(.callout).foregroundStyle(.secondary)
                if let issue = model.selectionRotation.issue {
                    Label(AppStrings.text(issue, locale: locale), systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange).textSelection(.enabled)
                }
            }
            Section("切换设置") {
                Picker("切换方式", selection: $draft.mode) {
                    Text("随机").tag("rand"); Text("顺序").tag("next")
                }
                HStack {
                    Text("切换间隔"); Spacer()
                    TextField("", text: $draft.minutesText).labelsHidden().textFieldStyle(.roundedBorder)
                        .frame(width: 72).multilineTextAlignment(.trailing)
                        .accessibilityLabel("切换间隔（分钟）").accessibilityIdentifier("selectionRotation.minutes")
                    Text("分钟")
                }.accessibilityElement(children: .contain)
                if draft.minutes == nil { Text("请输入 1-1440 之间的整数分钟。").foregroundStyle(.orange) }
                HStack {
                    Button(LocalizedStringKey(model.selectionRotation.active ? "应用并重新轮播" : "开启所选轮播")) {
                        guard let minutes = draft.minutes else { return }
                        model.startSelectedRotation(interval: minutes * 60, mode: draft.mode)
                        sync()
                    }.buttonStyle(.borderedProminent)
                        .disabled(draft.minutes == nil || collection.rotationCandidates.count < 2 || applied || model.isWorking)
                        .accessibilityIdentifier("selectionRotation.start")
                    Button("关闭轮播") { model.selectionRotation.stop() }
                        .disabled(!model.selectionRotation.active).accessibilityIdentifier("selectionRotation.stop")
                    if draft.isEdited { Button("还原当前设置", action: sync).buttonStyle(.link) }
                }
                Text("开启会立即更换桌面壁纸；关闭轮播会保留当前壁纸。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section {
                HStack {
                    Text(String(format: AppStrings.text("轮播列表：%d 项", locale: locale), collection.rotationItems.count))
                    Spacer()
                    Button("从图库添加", action: chooseWallpapers)
                    Button("清空列表") {
                        model.selectionRotation.stop()
                        collection.removeFromRotation(ids: Set(collection.rotationItems.map(\.id)))
                    }.disabled(collection.rotationItems.isEmpty || model.selectionRotation.switching)
                        .accessibilityIdentifier("selectionRotation.clear")
                }
                if collection.rotationCandidates.count < 2 {
                    Text("请至少添加两张未隐藏的壁纸。").font(.callout).foregroundStyle(.secondary)
                }
                ForEach(Array(collection.rotationItems.enumerated()), id: \.element.id) { index, item in
                    HStack(spacing: 10) {
                        Text(String(index + 1)).monospacedDigit().foregroundStyle(.secondary).frame(width: 24)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(item.title).lineLimit(2)
                            if collection.hiddenIDs.contains(item.id) {
                                Label("已隐藏，轮播会跳过", systemImage: "eye.slash").font(.caption).foregroundStyle(.secondary)
                            } else {
                                Text(LocalizedStringKey(item.kind == .scene ? "场景壁纸" : "视频壁纸"))
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }.frame(maxWidth: .infinity, alignment: .leading)
                        Button("上移", systemImage: "chevron.up") { collection.moveInRotation(item.id, offset: -1) }
                            .labelStyle(.iconOnly).disabled(index == 0)
                        Button("下移", systemImage: "chevron.down") { collection.moveInRotation(item.id, offset: 1) }
                            .labelStyle(.iconOnly).disabled(index + 1 == collection.rotationItems.count)
                        Button("移出轮播", systemImage: "minus.circle") {
                            collection.removeFromRotation(ids: [item.id])
                            if collection.rotationCandidates.isEmpty { model.selectionRotation.stop() }
                        }.labelStyle(.iconOnly).accessibilityIdentifier("selectionRotation.remove.\(index)")
                    }.disabled(model.selectionRotation.switching)
                }
            }
        }.formStyle(.grouped).frame(maxWidth: 760).frame(maxWidth: .infinity, maxHeight: .infinity)
            .onAppear { if !draft.isEdited { sync() } }
    }
    private func sync() { draft.sync(interval: collection.interval, mode: collection.mode, supportedModes: ["rand", "next"]) }
}
