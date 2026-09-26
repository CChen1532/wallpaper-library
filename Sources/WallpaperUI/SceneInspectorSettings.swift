import AppKit
import SwiftUI

/// Bindings capture the represented package instead of a shared selection draft.
struct SceneInspectorSettings: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @EnvironmentObject var model: LibraryModel
    @EnvironmentObject var scenePlayer: ScenePlayer
    @ObservedObject var store: ScenePreferencesStore
    @ObservedObject var properties: SceneUserPropertiesStore
    let package: URL
    @State private var showPlayback = false
    @State private var catalog: ScenePropertyCatalog = .empty
    @State private var catalogLoading = true

    private var preferences: ScenePreferences { store.preferences(for: package) }
    private var isPlaying: Bool { model.isActiveScene(package) }
    private var pendingChanges: Bool {
        preferences != scenePlayer.activePreferences ||
            properties.effectiveValues(for: package, catalog: catalog) != scenePlayer.activeUserPropertyValues
    }

    private func propertyValue(_ property: ScenePropertyDefinition) -> ScenePropertyValue {
        properties.value(for: property, package: package)
    }

    private func propertyBinding(_ property: ScenePropertyDefinition) -> Binding<ScenePropertyValue> {
        let representedPackage = package
        return Binding(get: { properties.value(for: property, package: representedPackage) },
                       set: { properties.save($0, for: property, package: representedPackage) })
    }

    private func booleanBinding(_ property: ScenePropertyDefinition) -> Binding<Bool> {
        let value = propertyBinding(property)
        return Binding(get: { if case .boolean(let flag) = value.wrappedValue { return flag }; return false },
                       set: { value.wrappedValue = .boolean($0) })
    }

    private func numberBinding(_ property: ScenePropertyDefinition) -> Binding<Double> {
        let value = propertyBinding(property)
        return Binding(get: { if case .number(let number) = value.wrappedValue { return number }; return 0 },
                       set: { value.wrappedValue = .number($0) })
    }

    private func stringBinding(_ property: ScenePropertyDefinition) -> Binding<String> {
        let value = propertyBinding(property)
        return Binding(get: { if case .string(let string) = value.wrappedValue { return string }; return "" },
                       set: { value.wrappedValue = .string($0) })
    }

    private func colorBinding(_ property: ScenePropertyDefinition) -> Binding<Color> {
        let value = stringBinding(property)
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

    @ViewBuilder private func propertyRow(_ property: ScenePropertyDefinition) -> some View {
        switch property.kind {
        case .boolean:
            HStack(spacing: 8) {
                Text(property.label)
                Spacer(minLength: 8)
                Toggle(property.label, isOn: booleanBinding(property)).labelsHidden()
            }.padding(10).modifier(HoverHighlight())
        case .slider(let minimum, let maximum, let step):
            VStack(alignment: .leading, spacing: 5) {
                HStack {
                    Text(property.label)
                    Spacer(minLength: 8)
                    Text(numberBinding(property).wrappedValue.formatted()).foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                Slider(value: numberBinding(property), in: minimum...maximum, step: step)
                    .accessibilityLabel(property.label)
            }.padding(10).modifier(HoverHighlight())
        case .choice(let choices):
            HStack(spacing: 8) {
                Text(property.label)
                Spacer(minLength: 8)
                Picker(property.label, selection: stringBinding(property)) {
                    ForEach(choices) { choice in Text(choice.label).tag(choice.value) }
                }.labelsHidden().frame(width: 120)
            }.padding(10).modifier(HoverHighlight())
        case .color:
            HStack(spacing: 8) {
                Text(property.label)
                Spacer(minLength: 8)
                ColorPicker(property.label, selection: colorBinding(property),
                            supportsOpacity: colorHasOpacity(property))
                    .labelsHidden()
            }.padding(10).modifier(HoverHighlight())
        case .textInput:
            VStack(alignment: .leading, spacing: 5) {
                Text(property.label)
                TextField(property.label, text: stringBinding(property)).textFieldStyle(.roundedBorder)
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
            Text(label)
            Spacer(minLength: 8)
            Toggle(label, isOn: value(keyPath)).labelsHidden().accessibilityLabel(label)
        }.padding(10).modifier(HoverHighlight())
    }

    private func picker<Value: Hashable, Options: View>(_ label: String,
        _ keyPath: WritableKeyPath<ScenePreferences, Value>, @ViewBuilder options: () -> Options) -> some View {
        HStack(spacing: 8) {
            Text(label)
            Spacer(minLength: 8)
            Picker(label, selection: value(keyPath), content: options)
                .labelsHidden().accessibilityLabel(label).frame(width: 112)
        }.padding(10).modifier(HoverHighlight())
    }

    var body: some View {
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
                        propertyRow(property)
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
                    .disabled(!preferences.mouseEnabled)
                Divider().padding(.horizontal, 10)
                picker("采样频率", \.inputHz) {
                    Text("30 Hz").tag(30)
                    Text("60 Hz").tag(60)
                    Text("120 Hz").tag(120)
                }.disabled(!preferences.mouseEnabled)
            }.background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 8))

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
                    toggle("跟随当前显示器", \.followsDisplay)
                        .help("关闭时固定在启动场景的显示器。")
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
                    .help("重新启动正在播放的这张壁纸以应用设置。")
            }
            Text(catalogLoading ? "正在读取设置…" : isPlaying && !pendingChanges ? "设置已保存并应用" : "自动保存，下次播放此壁纸时生效")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .contentTransition(.opacity)
                .animation(LibraryMotion.selection(reduceMotion), value: isPlaying && !pendingChanges)
        }.font(.callout).toggleStyle(.switch).controlSize(.small)
            .task(id: ScenePreferencesStore.identity(for: package)) {
                catalogLoading = true
                let loaded = await properties.loadCatalogInBackground(for: package)
                guard !Task.isCancelled else { return }
                catalog = loaded
                catalogLoading = false
            }
    }
}
