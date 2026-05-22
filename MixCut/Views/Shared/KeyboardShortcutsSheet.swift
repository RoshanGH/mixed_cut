import SwiftUI

/// 键盘快捷键帮助面板（⌘/ 召唤）
struct KeyboardShortcutsSheet: View {
    @Environment(\.dismiss) private var dismiss

    private struct ShortcutGroup: Identifiable {
        let id = UUID()
        let title: String
        let items: [(keys: String, label: String)]
    }

    private let groups: [ShortcutGroup] = [
        ShortcutGroup(title: "项目", items: [
            ("⌘N", "新建项目"),
            ("⌘B", "显示 / 隐藏侧边栏"),
            ("⌘,", "打开设置"),
            ("⌘W", "关闭窗口"),
        ]),
        ShortcutGroup(title: "导航", items: [
            ("⌘1", "项目概览"),
            ("⌘2", "素材导入"),
            ("⌘3", "分镜素材库"),
            ("⌘4", "混剪方案"),
            ("⌘5", "导出"),
        ]),
        ShortcutGroup(title: "分镜库 · 多选模式", items: [
            ("⌘A", "全选当前可见"),
            ("⌘D", "反选"),
            ("⌘0", "清空选择"),
            ("Esc", "退出多选"),
        ]),
        ShortcutGroup(title: "通用", items: [
            ("⌘/", "显示此快捷键面板"),
            ("Esc", "关闭对话框"),
            ("Enter", "确认 / 提交"),
        ]),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Image(systemName: "keyboard")
                    .font(.system(size: 18))
                    .foregroundStyle(Color.accentColor)
                Text("键盘快捷键")
                    .font(.system(size: 18, weight: .semibold))
                Spacer()
                Button {
                    dismiss()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 16))
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.cancelAction)
            }

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    ForEach(groups) { group in
                        VStack(alignment: .leading, spacing: 6) {
                            Text(group.title)
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(.tertiary)
                                .textCase(.uppercase)
                            VStack(spacing: 0) {
                                ForEach(group.items.indices, id: \.self) { idx in
                                    let item = group.items[idx]
                                    HStack {
                                        Text(item.label)
                                            .font(.system(size: 12))
                                        Spacer()
                                        Text(item.keys)
                                            .font(.system(size: 11, weight: .semibold, design: .monospaced))
                                            .foregroundStyle(.secondary)
                                            .padding(.horizontal, 8)
                                            .padding(.vertical, 3)
                                            .background(.quaternary.opacity(0.5))
                                            .clipShape(RoundedRectangle(cornerRadius: 5))
                                    }
                                    .padding(.vertical, 5)
                                    if idx != group.items.count - 1 {
                                        Divider().opacity(0.3)
                                    }
                                }
                            }
                            .padding(10)
                            .background(.quaternary.opacity(0.25))
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                        }
                    }
                }
            }
        }
        .padding(20)
        .frame(width: 480, height: 540)
    }
}
