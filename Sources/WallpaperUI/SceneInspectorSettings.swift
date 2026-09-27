import AppKit
import SwiftUI

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
    @State private var catalog: ScenePropertyCatalog = .empty
    @State private var catalogLoading = true
    @State private var availableDisplays = SceneDisplay.connected()

    private var preferences: ScenePreferences { store.preferences(for: package) }
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
                Slider(value: numberBinding(property, values: values), in: minimum...maximum, step: step)
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
                HStack {
                    Text("场景效果").font(.headline)
                    Spacer()
                    Text("仅此壁纸").font(.caption).foregroundStyle(.secondary)
                }
                VStack(spacing: 0) {
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

            Text(LocalizedStringKey(preferences.mouseEnabled
                 ? "效果取决于场景支持；采样频率不等于画面帧率。"
                 : "开启鼠标交互后，可设置点击响应和采样频率。"))
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            DisclosureGroup(isExpanded: Binding(get: { showPlayback }, set: { value in
                withAnimation(LibraryMotion.expansion(reduceMotion)) { showPlayback = value }
            })) {
                VStack(spacing: 0) {
                    picker("帧率上限", \.fps) {
                        Text("30 FPS").tag(30)
                        Text("60 FPS").tag(60)
                    }
                    picker("画面位置", \.cropMode) {
                        Text("自动适配").tag("auto")
                        Text("居中").tag("center")
                        Text("靠左").tag("left")
                        Text("靠右").tag("right")
                    }
                    displayPicker
                    Divider()
                    toggle("播放场景声音", \.soundEnabled)
                    toggle("音频响应", \.audioResponseEnabled)
                        .help("响应系统声音，需场景支持。首次使用可能需要系统录音权限。")
                }.background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 8))
                    .padding(.top, 8).padding(.bottom, 4)
            } label: {
                Text("播放与声音").frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 5).modifier(HoverHighlight())
            }
            if !catalogLoading && isPlaying && pendingChanges {
                Button("应用到此壁纸") {
                    let representedPackage = package
                    Task { await model.applyScenePreferences(for: representedPackage) }
                }.frame(maxWidth: .infinity).disabled(model.isWorking)
                    .help("场景效果会实时更新；播放与交互设置可能需要重新启动。")
            }
            Text(LocalizedStringKey(settingsStatus(pendingChanges: pendingChanges)))
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .contentTransition(.opacity)
                .animation(LibraryMotion.selection(reduceMotion), value: isPlaying && !pendingChanges)
        }.font(.callout).toggleStyle(.switch).controlSize(.small)
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
