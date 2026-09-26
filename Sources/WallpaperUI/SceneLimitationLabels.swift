import Foundation

enum SceneLimitationLabels {
    static let titles: [String: String] = [
        "animatedTexture": "动画或视频纹理受限",
        "colorKeyApproximation": "抠色仅为受限近似",
        "colorKeyDisabled": "抠色已禁用",
        "duplicateLayerID": "图层编号重复",
        "effects": "效果器暂不支持",
        "effectsOmitted": "预览未渲染效果器",
        "inspectionLimit": "资源检查达到限制",
        "invalidChildren": "子图层结构无效",
        "invalidJSONOrLimit": "资源数据无效或超出限制",
        "invalidLayer": "图层数据无效",
        "invalidMaterial": "材质数据无效",
        "invalidParent": "父图层引用无效",
        "invalidReference": "资源引用无效",
        "invalidTexture": "纹理数据无效",
        "invalidTextureSlots": "纹理列表结构无效",
        "largePackageInspectionDeferred": "大型场景包跳过受限静态分析",
        "layerSkipped": "受限预览跳过图层",
        "missingMaterial": "模型缺少材质",
        "missingParent": "父图层不存在",
        "missingResource": "引用资源缺失",
        "offlineVideoFrame": "视频仅离线取帧",
        "parentCycle": "父图层引用循环",
        "projected3D": "X/Y 轴旋转未还原",
        "referenceCycle": "资源引用循环",
        "rendererUnavailable": "完整场景渲染及桌面呈现未接入",
        "restrictedPreviewUnavailable": "受限静态预览生成失败",
        "runtimeResource": "运行时纹理未静态加载",
        "sceneFeature": "场景特性暂不支持",
        "script": "场景脚本未执行",
        "scriptDefault": "脚本参数仅使用默认值",
        "shader": "着色器尚未实现",
        "shaderApproximation": "着色器仅用基础贴图近似",
        "unsupportedLayer": "对象未静态合成",
        "unsupportedObject": "对象类型暂不支持",
        "userBinding": "用户属性未求值",
        "userDefault": "用户属性仅使用默认值",
        "windowlessVideoFrame": "视频仅无窗口取帧"
    ]

    static func title(for code: String) -> String {
        titles[code] ?? "其他限制（\(code)）"
    }
}
