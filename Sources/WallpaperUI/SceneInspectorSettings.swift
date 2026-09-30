import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Bindings capture the represented package instead of a shared selection draft.
struct SceneInspectorSettings: View {
    @Environment(\.locale) private var locale
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @EnvironmentObject var model: LibraryModel
    @EnvironmentObject var scenePlayer: ScenePlayer
    @ObservedObject var store: ScenePreferencesStore
    @ObservedObject var properties: SceneUserPropertiesStore
    let package: URL
    let catalogRevision: String
    @State private var showPlayback = false
    @State private var showQuality = false
    @State private var showAutomation = false
    @State private var importingImage = false
    @State private var operationMessage: String?
    @State private var confirmReset = false
    @State private var catalog: ScenePropertyCatalog = .empty
    @State private var catalogLoading = true
    @State private var availableDisplays = SceneDisplay.connected()

    private var preferences: ScenePreferences { model.playbackPreferences(for: package) }
    private var isPlaying: Bool { model.isActiveScene(package) }
    private var displaySelection: Binding<String> {
        let representedPackage = package
        return Binding(get: {
            let saved = store.preferences(for: representedPackage)
            return saved.followsDisplay ? "follow" : saved.displayUUID ?? "current"
        }, set: { selection in
            var saved = store.preferences(for: representedPackage)
            saved.followsDisplay = selection == "follow"
            let screen = availableDisplays.first { $0.uuid == selection }
            saved.displayUUID = screen?.uuid
            saved.displayName = screen?.name
            store.save(saved, for: representedPackage)
        })
    }

    private var displayPicker: some View {
        Group {
        if model.targetDisplayUUID != nil {
            LabeledContent("播放显示器", value: preferences.displayName ?? AppStrings.text("未连接", locale: locale))
            Text("在图库顶部选择目标屏幕；更换壁纸不会影响其他屏幕。")
                .font(.caption).foregroundStyle(.secondary)
        } else { legacyDisplayPicker }
        }
    }
    private var legacyDisplayPicker: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("播放显示器")
                Spacer(minLength: 8)
                Picker("播放显示器", selection: displaySelection) {
                    Text("跟随当前显示器").tag("follow")
                    Text("固定在启动显示器").tag("current")
                    ForEach(Array(availableDisplays.enumerated()), id: \.element.uuid) { index, display in
                        Text(availableDisplays.filter { $0.name == display.name }.count > 1
                             ? "\(display.name) (\(index + 1))" : display.name).tag(display.uuid)
                    }
                    if let uuid = preferences.displayUUID, !availableDisplays.contains(where: { $0.uuid == uuid }) {
                        Text((preferences.displayName ?? AppStrings.text("所选显示器", locale: locale)) +
                             " · " + AppStrings.text("未连接", locale: locale)).tag(uuid)
                    }
                }.labelsHidden().frame(maxWidth: 172)
            }
            Text(LocalizedStringKey(preferences.followsDisplay
                ? "跟随当前操作所在的显示器，一次仅在一个屏幕播放。"
                : preferences.displayUUID != nil
                    ? "所选显示器断开时使用可用屏幕，重新连接后自动返回。"
                    : "固定在启动场景的显示器；断开后使用其他可用屏幕。"))
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }.padding(10).modifier(HoverHighlight())
    }
    private func settingsStatus(pendingChanges: Bool) -> String {
        if catalogLoading { return "正在读取设置…" }
        if isPlaying {
            return pendingChanges
                ? "已保存，尚未应用到正在播放的壁纸。点击“应用到此壁纸”后生效。"
                : "设置已保存并应用"
        }
        return "自动保存，下次播放此壁纸时生效"
    }

    private func propertyBinding(_ property: ScenePropertyDefinition, values: [String: ScenePropertyValue]) -> Binding<ScenePropertyValue> {
        let representedPackage = package
        return Binding(get: { values[property.id] ?? property.preferredDefault },
                       set: { properties.save($0, for: property, package: representedPackage) })
    }

    private func booleanBinding(_ property: ScenePropertyDefinition, values: [String: ScenePropertyValue]) -> Binding<Bool> {
        let value = propertyBinding(property, values: values)
        return Binding(get: { if case .boolean(let flag) = value.wrappedValue { return flag }; return false },
                       set: { value.wrappedValue = .boolean($0) })
    }

    private func numberBinding(_ property: ScenePropertyDefinition, values: [String: ScenePropertyValue]) -> Binding<Double> {
        let value = propertyBinding(property, values: values)
        return Binding(get: { if case .number(let number) = value.wrappedValue { return number }; return 0 },
                       set: { value.wrappedValue = .number($0) })
    }

    // SwiftUI's Slider(step:) asks AppKit to draw a tick for every increment.
    // Some author sliders have thousands of increments, which makes scrolling
    // spend most of its main-thread time in NSSliderTickMarks.drawRect.
    // Keep the saved step semantics without creating those visual tick marks.
    private func snappedSliderValue(_ value: Binding<Double>, in range: ClosedRange<Double>, step: Double) -> Binding<Double> {
        Binding(get: { value.wrappedValue }, set: { raw in
            let snapped = range.lowerBound + ((raw - range.lowerBound) / step).rounded() * step
            value.wrappedValue = min(range.upperBound, max(range.lowerBound, snapped))
        })
    }

    private func stringBinding(_ property: ScenePropertyDefinition, values: [String: ScenePropertyValue]) -> Binding<String> {
        let value = propertyBinding(property, values: values)
        return Binding(get: { if case .string(let string) = value.wrappedValue { return string }; return "" },
                       set: { value.wrappedValue = .string($0) })
    }

    private func colorBinding(_ property: ScenePropertyDefinition, values: [String: ScenePropertyValue]) -> Binding<Color> {
        let value = stringBinding(property, values: values)
        return Binding(get: {
            let channels = value.wrappedValue.split(whereSeparator: \.isWhitespace).compactMap { Double($0) }
            guard channels.count >= 3 else { return .white }
            return Color(red: channels[0], green: channels[1], blue: channels[2],
                         opacity: channels.count == 4 ? channels[3] : 1)
        }, set: { color in
            guard let rgb = NSColor(color).usingColorSpace(.deviceRGB) else { return }
            let sourceCount = value.wrappedValue.split(whereSeparator: \.isWhitespace).count
            var channels = [rgb.redComponent, rgb.greenComponent, rgb.blueComponent]
            if sourceCount == 4 { channels.append(rgb.alphaComponent) }
            value.wrappedValue = channels.map { String(Double(min(1, max(0, $0)))) }.joined(separator: " ")
        })
    }

    private func colorHasOpacity(_ property: ScenePropertyDefinition) -> Bool {
        guard case .string(let value) = property.sourceDefault else { return false }
        return value.split(whereSeparator: \.isWhitespace).count == 4
    }

    @ViewBuilder private func propertyRow(_ property: ScenePropertyDefinition, values: [String: ScenePropertyValue]) -> some View {
        switch property.kind {
        case .boolean:
            HStack(spacing: 8) {
                Text(LocalizedStringKey(property.label))
                Spacer(minLength: 8)
                Toggle(LocalizedStringKey(property.label), isOn: booleanBinding(property, values: values))
                    .labelsHidden().accessibilityLabel(AppStrings.text(property.label, locale: locale))
            }.padding(10).modifier(HoverHighlight())
        case .slider(let minimum, let maximum, let step):
            VStack(alignment: .leading, spacing: 5) {
                HStack {
                    Text(LocalizedStringKey(property.label))
                    Spacer(minLength: 8)
                    Text(numberBinding(property, values: values).wrappedValue.formatted()).foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                Slider(value: snappedSliderValue(numberBinding(property, values: values),
                                                 in: minimum...maximum, step: step), in: minimum...maximum)
                    .accessibilityLabel(AppStrings.text(property.label, locale: locale))
            }.padding(10).modifier(HoverHighlight())
        case .choice(let choices):
            HStack(spacing: 8) {
                Text(LocalizedStringKey(property.label))
                Spacer(minLength: 8)
                Picker(LocalizedStringKey(property.label), selection: stringBinding(property, values: values)) {
                    ForEach(choices) { choice in Text(LocalizedStringKey(choice.label)).tag(choice.value) }
                }.labelsHidden().frame(width: 120)
            }.padding(10).modifier(HoverHighlight())
        case .color:
            HStack(spacing: 8) {
                Text(LocalizedStringKey(property.label))
                Spacer(minLength: 8)
                ColorPicker(LocalizedStringKey(property.label), selection: colorBinding(property, values: values),
                            supportsOpacity: colorHasOpacity(property))
                    .labelsHidden()
            }.padding(10).modifier(HoverHighlight())
        case .imageFile:
            VStack(alignment: .leading, spacing: 6) {
                Text(LocalizedStringKey(property.label))
                HStack {
                    Button("选择图片…") { chooseImage(property) }.disabled(importingImage)
                    Button("恢复默认") { properties.save(property.sourceDefault, for: property, package: package) }
                }
                if case .texture(let path) = propertyBinding(property, values: values).wrappedValue, !path.isEmpty {
                    Text(URL(fileURLWithPath: path).lastPathComponent).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }.padding(10)
        case .shortcut:
            VStack(alignment: .leading, spacing: 6) {
                Text(LocalizedStringKey(property.label))
                TextField("网页地址或所选文件", text: stringBinding(property, values: values)).textFieldStyle(.roundedBorder)
                Button("选择应用或文件…") { chooseShortcut(property) }
            }.padding(10)
        case .textInput:
            VStack(alignment: .leading, spacing: 5) {
                Text(LocalizedStringKey(property.label))
                TextField(LocalizedStringKey(property.label), text: stringBinding(property, values: values)).textFieldStyle(.roundedBorder)
            }.padding(10).modifier(HoverHighlight())
        }
    }

    private func value<Value>(_ keyPath: WritableKeyPath<ScenePreferences, Value>) -> Binding<Value> {
        let representedPackage = package
        return Binding(get: { store.preferences(for: representedPackage)[keyPath: keyPath] }, set: { value in
            var saved = store.preferences(for: representedPackage)
            saved[keyPath: keyPath] = value
            store.save(saved, for: representedPackage)
        })
    }

    private func toggle(_ label: String, _ keyPath: WritableKeyPath<ScenePreferences, Bool>) -> some View {
        HStack(spacing: 8) {
            Text(LocalizedStringKey(label))
            Spacer(minLength: 8)
            Toggle(LocalizedStringKey(label), isOn: value(keyPath)).labelsHidden().accessibilityLabel(AppStrings.text(label, locale: locale))
        }.padding(10).modifier(HoverHighlight())
    }

    private func picker<Value: Hashable, Options: View>(_ label: String,
        _ keyPath: WritableKeyPath<ScenePreferences, Value>, @ViewBuilder options: () -> Options) -> some View {
        HStack(spacing: 8) {
            Text(LocalizedStringKey(label))
            Spacer(minLength: 8)
            Picker(LocalizedStringKey(label), selection: value(keyPath), content: options)
                .labelsHidden().accessibilityLabel(AppStrings.text(label, locale: locale)).frame(width: 112)
        }.padding(10).modifier(HoverHighlight())
    }

    private func slider(_ label: String, _ path: WritableKeyPath<ScenePreferences, Double>, range: ClosedRange<Double>, step: Double) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack { Text(LocalizedStringKey(label)); Spacer(); Text(value(path).wrappedValue.formatted(.number.precision(.fractionLength(0...2)))).monospacedDigit().foregroundStyle(.secondary) }
            Slider(value: snappedSliderValue(value(path), in: range, step: step), in: range)
                .accessibilityLabel(AppStrings.text(label, locale: locale))
        }.padding(10)
    }

    private func chooseImage(_ property: ScenePropertyDefinition) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]; panel.allowsMultipleSelection = false; panel.canChooseDirectories = false
        let represented = package
        panel.begin { response in
            guard response == .OK, let source = panel.url else { return }
            importingImage = true
            Task { @MainActor in
                defer { importingImage = false }
                do {
                    let result = try await Task.detached(priority: .utility) { try SceneImageImport.importImage(source, for: represented) }.value
                    properties.save(.texture(result.path), for: property, package: represented)
                } catch { model.error = error.localizedDescription }
            }
        }
    }
    private func chooseShortcut(_ property: ScenePropertyDefinition) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true; panel.canChooseFiles = true; panel.allowsMultipleSelection = false
        let represented = package
        panel.begin { response in
            guard response == .OK, let file = panel.url else { return }
            guard let target = SceneShortcut.target(file.path) else { model.error = AppStrings.text("不支持此快捷入口，请选择应用、文件夹、文档或媒体文件", locale: locale); return }
            properties.save(.string(target.path), for: property, package: represented)
        }
    }
    private func exportFile(screenshot: Bool) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = screenshot ? [.png] : [.json]
        panel.nameFieldStringValue = screenshot ? "Wallpaper.png" : "SceneData.json"
        let represented = package
        panel.begin { response in
            guard response == .OK, let destination = panel.url else { return }
            runExport(screenshot ? .screenshot(destination) : .storage(destination), package: represented)
        }
    }
    private func resetData() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]; panel.nameFieldStringValue = "SceneData-backup.json"
        panel.message = AppStrings.text("先保存当前数据的备份，再重置此场景。", locale: locale)
        let represented = package
        panel.begin { response in
            guard response == .OK, let backup = panel.url else { return }
            runExport(.resetStorage(backup), package: represented)
        }
    }
    private func runExport(_ action: SceneExportAction, package: URL) {
        Task { @MainActor in
            do { try await scenePlayer.export(action, for: package); operationMessage = "操作已完成" }
            catch { model.error = error.localizedDescription }
        }
    }

    var body: some View {
        // Resolve the package and saved data once per render, not once per getter.
        // Saves still validate against current metadata and notify this view.
        let values = properties.effectiveValues(for: package, catalog: catalog)
        let preferences = self.preferences
        let pendingChanges = preferences != scenePlayer.activePreferences ||
            values != scenePlayer.activeUserPropertyValues
        VStack(alignment: .leading, spacing: 12) {
            if catalogLoading { ProgressView("正在读取场景效果…").font(.caption) }
            if !catalog.properties.isEmpty {
                Text("场景效果").font(.headline)
                // Large scenes can expose 100+ native controls. Only build rows near
                // the inspector's visible scroll region to keep selection responsive.
                LazyVStack(spacing: 0) {
                    ForEach(Array(catalog.properties.enumerated()), id: \.element.id) { index, property in
                        if index > 0 { Divider().padding(.horizontal, 10) }
                        propertyRow(property, values: values)
                    }
                }.background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 8))
            }
            HStack {
                Text("场景交互").font(.headline)
                Spacer()
                Text("仅此壁纸").font(.caption).foregroundStyle(.secondary)
            }
            VStack(spacing: 0) {
                toggle("鼠标交互", \.mouseEnabled)
                    .help("控制此场景的视差、粒子跟随和脚本输入，效果取决于场景。")
                Divider().padding(.horizontal, 10)
                toggle("响应鼠标点击", \.mouseButtonsEnabled)
                    .help("允许支持点击事件的场景响应鼠标按键；需先开启鼠标交互。")
                    .disabled(!preferences.mouseEnabled)
                Divider().padding(.horizontal, 10)
                picker("采样频率", \.inputHz) {
                    Text("30 Hz").tag(30)
                    Text("60 Hz").tag(60)
                    Text("120 Hz").tag(120)
                }.disabled(!preferences.mouseEnabled)
                    .help("鼠标位置的采样频率，与画面帧率不同；需先开启鼠标交互。")
            }.background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 8))

            DisclosureGroup(isExpanded: Binding(get: { showPlayback }, set: { value in
                withAnimation(LibraryMotion.expansion(reduceMotion)) { showPlayback = value }
            })) {
                VStack(spacing: 0) {
                    picker("帧率上限", \.fps) {
                        Text("15 FPS").tag(15)
                        Text("30 FPS").tag(30)
                        Text("60 FPS").tag(60)
                        Text("120 FPS").tag(120)
                    }
                    picker("画面位置", \.cropMode) {
                        Text("自动适配").tag("auto")
                        Text("居中").tag("center")
                        Text("靠左").tag("left")
                        Text("靠右").tag("right")
                        Text("自定义").tag("custom")
                    }
                    if preferences.cropMode == "custom" { slider("横向位置", \.positionX, range: 0...1, step: 0.01) }
                    slider("纵向位置", \.positionY, range: 0...1, step: 0.01)
                    picker("填充方式", \.fillMode) {
                        Text("铺满裁切").tag("cover")
                        Text("完整显示").tag("contain")
                        Text("拉伸").tag("stretch")
                    }
                    slider("动画速度", \.speed, range: 0.25...2, step: 0.05)
                    displayPicker
                    Divider()
                    toggle("播放场景声音", \.soundEnabled)
                    slider("场景音量", \.volume, range: 0...1, step: 0.01)
                    toggle("音频响应", \.audioResponseEnabled)
                        .help("响应系统声音，需场景支持。首次使用可能需要系统录音权限。")
                }.background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 8))
                    .padding(.top, 8).padding(.bottom, 4)
            } label: {
                Text("播放与声音").frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 5).modifier(HoverHighlight())
            }
            DisclosureGroup("画质", isExpanded: $showQuality) {
                VStack(spacing: 0) {
                    slider("渲染比例", \.renderScale, range: 0.25...1, step: 0.05)
                    toggle("MetalFX 放大", \.metalFX)
                    picker("多重采样抗锯齿", \.msaa) {
                        Text("关闭").tag(1)
                        Text("2×").tag(2)
                        Text("4×").tag(4)
                        Text("8×").tag(8)
                    }
                }.background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 8))
                Text("画质修改需重新加载；降低渲染比例可减少 GPU 负担，MetalFX 效果取决于设备支持。").font(.caption).foregroundStyle(.secondary)
            }
            DisclosureGroup("自动控制与媒体", isExpanded: $showAutomation) {
                VStack(spacing: 0) {
                    toggle("自动节能", \.energySaving)
                    toggle("前台窗口覆盖屏幕时暂停", \.pauseWhenCovered)
                    toggle("显示当前歌曲信息", \.mediaInfoEnabled)
                    if catalog.properties.contains(where: { $0.kind == .shortcut }) {
                        toggle("允许场景快捷入口", \.shortcutsEnabled)
                    }
                }.background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 8))
                Text("节能时降至 15 FPS；温度过高时暂停。手动暂停不会被自动恢复。").font(.caption).foregroundStyle(.secondary)
                if preferences.mediaInfoEnabled && isPlaying {
                    Text(LocalizedStringKey(scenePlayer.mediaStatus)).font(.caption).foregroundStyle(.secondary)
                }
            }
            if isPlaying && scenePlayer.supportsControls {
                HStack {
                    Button(LocalizedStringKey(scenePlayer.manualPause ? "继续场景" : "暂停场景")) { scenePlayer.togglePause() }
                    Menu("更多场景操作") {
                        Button("导出当前画面…") { exportFile(screenshot: true) }
                        Button("导出场景数据…") { exportFile(screenshot: false) }
                        Button("重置场景数据…") { confirmReset = true }
                    }.disabled(scenePlayer.isTransitioning)
                }
                if let operationMessage { Text(LocalizedStringKey(operationMessage)).font(.caption).foregroundStyle(.secondary) }
            }
            if !catalogLoading && isPlaying && pendingChanges {
                Button("应用到此壁纸") {
                    let representedPackage = package
                    Task { await model.applyScenePreferences(for: representedPackage) }
                }.frame(maxWidth: .infinity).disabled(model.isWorking)
                    .help("效果、声音、速度和画面位置可实时更新；画质与输入设置需要重新启动。")
            }
            Text(LocalizedStringKey(settingsStatus(pendingChanges: pendingChanges)))
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .contentTransition(.opacity)
                .animation(LibraryMotion.selection(reduceMotion), value: isPlaying && !pendingChanges)
        }.font(.callout).toggleStyle(.switch).controlSize(.small)
            .confirmationDialog("重置此场景的数据？", isPresented: $confirmReset) {
            Button("保存备份并重置") { resetData() }
            Button("取消", role: .cancel) {}
        } message: { Text("将清除脚本保存的数据，壁纸效果设置保持不变。") }
        .task(id: catalogRevision) {
                catalogLoading = true
                catalog = .empty
                let loaded = await properties.loadCatalogInBackground(for: package)
                guard !Task.isCancelled else { return }
                catalog = loaded
                catalogLoading = false
            }
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification)) { _ in
                availableDisplays = SceneDisplay.connected()
            }
    }
}
