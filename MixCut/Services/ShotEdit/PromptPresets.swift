import Foundation

/// 分镜头 AI 编辑的预设提示词（做进 UI 快捷选择）。
/// 使用规律（见 Phase 0 实测）：like-for-like 同类替换效果好；
/// 新旧物体形状/动作差异过大会形变穿帮，故预设以同类替换/换背景/换颜色为主。
enum PromptPresets {
    struct Group: Identifiable {
        let id = UUID()
        let title: String
        let prompts: [String]
    }

    static let groups: [Group] = [
        Group(title: "换背景", prompts: [
            "把背景换成明亮整洁的现代白色厨房，保持前景的手和产品完全不变",
            "把背景换成夕阳下的海边沙滩",
            "把画面背景里那幅画换成梵高的《星月夜》",
        ]),
        Group(title: "换主体外观 / 人物", prompts: [
            "把画面里的长发女孩换成利落的短发",
            "把手里拿的可乐换成一瓶雪碧，手的姿势和背景保持不变",
        ]),
        Group(title: "换颜色 / 材质", prompts: [
            "把女孩的睡衣从粉色换成蓝色",
            "把红色马克杯换成透明玻璃杯",
        ]),
        Group(title: "整体风格", prompts: [
            "把整个画面调成清晨柔光、暖色调",
        ]),
    ]
}
