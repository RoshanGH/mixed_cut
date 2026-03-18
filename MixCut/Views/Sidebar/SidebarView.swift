import SwiftUI

struct SidebarView: View {
    @Bindable var projectVM: ProjectViewModel
    @Binding var selectedNavItem: NavigationItem?

    @State private var projectToDelete: Project?
    @State private var showSettings = false
    @State private var hoveredProject: UUID?
    @State private var hoveredNavItem: NavigationItem?
    @State private var isSettingsHovered = false

    private var activeProjects: [Project] {
        projectVM.projects.filter { $0.status != .archived }
    }

    var body: some View {
        VStack(spacing: 0) {
            // 标题栏
            HStack(spacing: 8) {
                Image(systemName: "film.stack.fill")
                    .font(.system(size: 14))
                    .foregroundStyle(.blue)
                Text("MixCut")
                    .font(.system(size: 14, weight: .bold))
                Spacer()
            }
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
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(isSettingsHovered ? Color.secondary.opacity(0.08) : Color.clear)
                )
            }
            .buttonStyle(.plain)
            .foregroundStyle(.tertiary)
            .onHover { hovering in
                withAnimation(.easeOut(duration: 0.15)) {
                    isSettingsHovered = hovering
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
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
        return Button {
            projectVM.selectedProject = project
            if selectedNavItem == nil {
                selectedNavItem = .overview
            }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: isSelected ? "film.fill" : "film")
                    .font(.system(size: 11))
                    .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
                    .frame(width: 18)
                Text(project.name)
                    .font(.system(size: 12))
                    .lineLimit(1)
                    .foregroundStyle(isSelected ? Color.accentColor : Color.primary)
                Spacer()
                if isSelected {
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
        .contextMenu {
            Button("归档") {
                projectVM.archiveProject(project)
            }
            Divider()
            Button("删除", role: .destructive) {
                projectToDelete = project
            }
        }
    }

    private func navRow(_ item: NavigationItem) -> some View {
        let isSelected = selectedNavItem == item && projectVM.selectedProject != nil
        let isHovered = hoveredNavItem == item
        return Button {
            guard projectVM.selectedProject != nil else { return }
            selectedNavItem = item
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
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
        }
        .buttonStyle(.plain)
        .foregroundStyle(Color.accentColor.opacity(0.8))
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
