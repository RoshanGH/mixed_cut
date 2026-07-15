import SwiftUI

struct SidebarView: View {
    @Bindable var projectVM: ProjectViewModel
    @Binding var selectedNavItem: NavigationItem?

    @State private var projectToDelete: Project?
    @State private var showSettings = false
    @State private var hoveredProject: UUID?
    @State private var hoveredNavItem: NavigationItem?
    @State private var isSettingsHovered = false
    @State private var hasAPIKey: Bool = true
    @State private var hasWhisperModel: Bool = true
    @State private var renamingProjectID: UUID?
    @State private var renameText: String = ""
    @State private var showWeChatPopover = false
    @State private var isWeChatHovered = false
    @State private var didCopyWeChat = false

    /// 客服微信号（与手机号一致）
    private let weChatID = "13462890087"

    private var hasMissingDependency: Bool { !hasAPIKey || !hasWhisperModel }

    private var activeProjects: [Project] {
        projectVM.projects.filter { $0.status != .archived }
    }

    var body: some View {
        VStack(spacing: 0) {
            // 标题栏（点击回 Welcome）
            Button {
                projectVM.selectedProject = nil
                selectedNavItem = nil
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "film.stack.fill")
                        .font(.system(size: 14))
                        .foregroundStyle(.blue)
                    Text("MixCut")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(.primary)
                    Spacer()
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("回到欢迎页")
            .padding(.horizontal, 16)
            .padding(.vertical, 14)

            Divider()

            // 内容列表
            ScrollView {
                VStack(alignment: .leading, spacing: 4) {
                    // 项目区域
                    sectionHeader("项目")
                        .padding(.top, 4)

                    ForEach(activeProjects) { project in
                        projectRow(project)
                    }

                    newProjectButton
                        .padding(.top, 2)

                    // 工作区
                    sectionHeader("工作区")
                        .padding(.top, 16)

                    ForEach(NavigationItem.allCases) { item in
                        navRow(item)
                    }
                    .opacity(projectVM.selectedProject == nil ? 0.35 : 1.0)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
            }

            Divider()

            // 微信入口（点击弹出微信号卡片）
            Button {
                showWeChatPopover = true
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "message.fill")
                        .font(.system(size: 12))
                        .frame(width: 20)
                    Text("微信")
                        .font(.system(size: 12))
                    Spacer()
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(isWeChatHovered ? Color.secondary.opacity(0.08) : Color.clear)
                )
            }
            .buttonStyle(.plain)
            .foregroundStyle(.tertiary)
            .onHover { hovering in
                withAnimation(.easeOut(duration: 0.15)) {
                    isWeChatHovered = hovering
                }
            }
            .popover(isPresented: $showWeChatPopover, arrowEdge: .trailing) {
                weChatCard
            }
            .onChange(of: showWeChatPopover) { _, isShown in
                if !isShown { didCopyWeChat = false }
            }
            .padding(.horizontal, 12)
            .padding(.top, 8)

            // 底部设置按钮
            Button {
                showSettings = true
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "gear")
                        .font(.system(size: 12))
                        .frame(width: 20)
                    Text("设置")
                        .font(.system(size: 12))
                    Spacer()
                    if hasMissingDependency {
                        // 未配置依赖时显示橙色感叹号
                        Image(systemName: "exclamationmark.circle.fill")
                            .font(.system(size: 11))
                            .foregroundStyle(.orange)
                            .help(hasAPIKey ? "Whisper 语音模型未下载" : "AI API Key 未配置")
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(isSettingsHovered ? Color.secondary.opacity(0.08) : Color.clear)
                )
            }
            .buttonStyle(.plain)
            .foregroundStyle(hasMissingDependency ? .secondary : .tertiary)
            .onHover { hovering in
                withAnimation(.easeOut(duration: 0.15)) {
                    isSettingsHovered = hovering
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
        .onAppear { refreshDependencyStatus() }
        .onChange(of: showSettings) { _, newValue in
            // Settings 关闭时重新检查
            if !newValue { refreshDependencyStatus() }
        }
        .sheet(isPresented: $showSettings) {
            SettingsView()
        }
        .background(Color(nsColor: .controlBackgroundColor))
        .sheet(isPresented: $projectVM.isCreatingProject) {
            NewProjectSheet(projectVM: projectVM)
        }
        .alert("确认删除项目", isPresented: Binding(
            get: { projectToDelete != nil },
            set: { if !$0 { projectToDelete = nil } }
        )) {
            Button("取消", role: .cancel) {
                projectToDelete = nil
            }
            Button("删除", role: .destructive) {
                if let project = projectToDelete {
                    if projectVM.selectedProject?.id == project.id {
                        selectedNavItem = .overview
                    }
                    projectVM.deleteProject(project)
                }
                projectToDelete = nil
            }
        } message: {
            if let project = projectToDelete {
                Text("确定要删除项目「\(project.name)」吗？所有视频、分镜和方案数据都将被删除，此操作不可恢复。")
            }
        }
    }

    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(.tertiary)
            .textCase(.uppercase)
            .padding(.horizontal, 8)
            .padding(.bottom, 4)
    }

    private func projectRow(_ project: Project) -> some View {
        let isSelected = projectVM.selectedProject?.id == project.id
        let isHovered = hoveredProject == project.id
        let isRenaming = renamingProjectID == project.id
        return Button {
            if !isRenaming {
                projectVM.selectedProject = project
                if selectedNavItem == nil {
                    selectedNavItem = .overview
                }
            }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: isSelected ? "film.fill" : "film")
                    .font(.system(size: 11))
                    .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
                    .frame(width: 18)
                if isRenaming {
                    TextField("项目名", text: $renameText, onCommit: {
                        commitRename(project)
                    })
                    .font(.system(size: 12))
                    .textFieldStyle(.plain)
                    .onExitCommand {
                        renamingProjectID = nil
                    }
                } else {
                    Text(project.name)
                        .font(.system(size: 12))
                        .lineLimit(1)
                        .foregroundStyle(isSelected ? Color.accentColor : Color.primary)
                }
                Spacer()
                if isSelected && !isRenaming {
                    Circle()
                        .fill(Color.accentColor)
                        .frame(width: 5, height: 5)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(isSelected ? Color.accentColor.opacity(0.1) :
                          isHovered ? Color.secondary.opacity(0.06) : Color.clear)
            )
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.15)) {
                hoveredProject = hovering ? project.id : nil
            }
        }
        .simultaneousGesture(
            TapGesture(count: 2).onEnded {
                renameText = project.name
                renamingProjectID = project.id
            }
        )
        .contextMenu {
            Button("重命名") {
                renameText = project.name
                renamingProjectID = project.id
            }
            Divider()
            Button("删除", role: .destructive) {
                projectToDelete = project
            }
        }
    }

    private func commitRename(_ project: Project) {
        let name = renameText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !name.isEmpty, name != project.name {
            projectVM.renameProject(project, to: name)
            ToastCenter.shared.show("已重命名为「\(name)」", icon: "pencil")
        }
        renamingProjectID = nil
    }

    private func navRow(_ item: NavigationItem) -> some View {
        let isSelected = selectedNavItem == item && projectVM.selectedProject != nil
        let isHovered = hoveredNavItem == item
        let shortcut = shortcutHint(for: item)
        return Button {
            guard projectVM.selectedProject != nil else { return }
            withAnimation(.easeOut(duration: 0.18)) {
                selectedNavItem = item
            }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: item.icon)
                    .font(.system(size: 12))
                    .frame(width: 18)
                    .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
                Text(item.rawValue)
                    .font(.system(size: 12))
                    .foregroundStyle(isSelected ? Color.accentColor : Color.primary)
                Spacer()
                if isHovered, !shortcut.isEmpty {
                    Text(shortcut)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.tertiary)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(isSelected ? Color.accentColor.opacity(0.1) :
                          isHovered ? Color.secondary.opacity(0.06) : Color.clear)
            )
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.15)) {
                hoveredNavItem = hovering ? item : nil
            }
        }
        .disabled(projectVM.selectedProject == nil)
        .help(shortcut.isEmpty ? item.rawValue : "\(item.rawValue) (\(shortcut))")
    }

    private func refreshDependencyStatus() {
        hasAPIKey = KeychainHelper.hasAPIKey(for: KeychainHelper.activeProvider)
        hasWhisperModel = ASRService().isModelAvailable()
    }

    private func shortcutHint(for item: NavigationItem) -> String {
        switch item {
        case .overview:       return "⌘1"
        case .importMedia:    return "⌘2"
        case .segmentLibrary: return "⌘3"
        case .schemes:        return "⌘4"
        case .export:         return "⌘5"
        }
    }

    /// 微信号卡片（点击侧边栏「微信」弹出）
    private var weChatCard: some View {
        VStack(spacing: 12) {
            Text("添加我的微信加入交流群")
                .font(.system(size: 13, weight: .semibold))

            VStack(spacing: 4) {
                Text("微信号")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                Text(weChatID)
                    .font(.system(size: 16, weight: .medium))
                    .textSelection(.enabled)
            }

            Button {
                copyWeChatID()
            } label: {
                Text(didCopyWeChat ? "已复制 ✓" : "复制微信号")
                    .font(.system(size: 12))
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
        }
        .padding(20)
        .frame(width: 200)
    }

    private func copyWeChatID() {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(weChatID, forType: .string)
        withAnimation(.easeOut(duration: 0.15)) {
            didCopyWeChat = true
        }
    }

    private var newProjectButton: some View {
        Button {
            projectVM.isCreatingProject = true
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "plus.circle.fill")
                    .font(.system(size: 12))
                    .frame(width: 18)
                Text("新建项目")
                    .font(.system(size: 12))
                Spacer()
                Text("⌘N")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
        }
        .buttonStyle(.plain)
        .foregroundStyle(Color.accentColor.opacity(0.8))
        .help("新建项目 (⌘N)")
    }
}

/// 新建项目弹窗
struct NewProjectSheet: View {
    @Bindable var projectVM: ProjectViewModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 24) {
            VStack(spacing: 6) {
                Image(systemName: "film.stack.fill")
                    .font(.system(size: 24))
                    .foregroundStyle(.blue)
                Text("新建项目")
                    .font(.system(size: 16, weight: .semibold))
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("项目名称")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                TextField("输入项目名称", text: $projectVM.newProjectName)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 300)
                    .onSubmit {
                        guard !projectVM.newProjectName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
                        projectVM.createProject()
                        dismiss()
                    }
            }

            HStack(spacing: 12) {
                Button("取消") {
                    projectVM.newProjectName = ""
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)

                Button {
                    projectVM.createProject()
                    dismiss()
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "plus")
                            .font(.system(size: 11))
                        Text("创建")
                    }
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .disabled(projectVM.newProjectName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(28)
    }
}
