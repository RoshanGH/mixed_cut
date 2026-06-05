import SwiftUI
import SwiftData

/// 侧边栏导航项
extension Notification.Name {
    static let mixCutNavigate = Notification.Name("mixCutNavigate")
    static let mixCutNewProject = Notification.Name("mixCutNewProject")
    static let mixCutShowShortcuts = Notification.Name("mixCutShowShortcuts")
    /// 撤销 / 重做后广播：当前视图据此重载，避免显示已回滚 / 恢复前的陈旧数据
    static let mixCutDataDidUndo = Notification.Name("mixCutDataDidUndo")
}

enum NavigationItem: String, Hashable, CaseIterable, Identifiable {
    case overview = "项目概览"
    case importMedia = "素材导入"
    case segmentLibrary = "分镜素材库"
    case schemes = "混剪方案"
    case export = "导出"

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .overview: return "rectangle.3.group"
        case .importMedia: return "square.and.arrow.down"
        case .segmentLibrary: return "film.stack"
        case .schemes: return "list.bullet.clipboard"
        case .export: return "square.and.arrow.up"
        }
    }
}

struct ContentView: View {
    @Environment(\.modelContext) private var modelContext

    @State private var projectVM = ProjectViewModel()
    @State private var importVM = ImportViewModel()
    @State private var segmentLibraryVM = SegmentLibraryViewModel()
    @State private var schemeVM = SchemeViewModel()
    @State private var updateChecker = UpdateCheckerViewModel()

    @State private var selectedNavItem: NavigationItem? = .overview

    @AppStorage("hasCompletedOnboarding") private var hasCompletedOnboarding = false
    @State private var sidebarVisible = true
    @State private var showShortcuts = false

    var body: some View {
        ZStack {
        VStack(spacing: 0) {
        // 新版本横幅（GitHub 优先，failover Gitee；hasUpdate==true 时才显示）
        UpdateBanner(viewModel: updateChecker)

        HStack(spacing: 0) {
            // 侧边栏（可隐藏，⌘B）
            if sidebarVisible {
                SidebarView(
                    projectVM: projectVM,
                    selectedNavItem: $selectedNavItem
                )
                .frame(width: 220)
                .transition(.move(edge: .leading).combined(with: .opacity))

                Divider()
            }

            // 详情区域 — 切换菜单 / 项目时加平滑过渡
            // 关键：不用 .id() 强制重建，否则每次切换都从零构造大量 NSView/AVPlayer，
            // 直接慢 500-1000ms。让 SwiftUI 自然 diff 重用就好。
            VStack(spacing: 0) {
                if let project = projectVM.selectedProject {
                    detailView(for: project)
                } else {
                    WelcomeView(projectVM: projectVM)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .onAppear {
            projectVM.setModelContext(modelContext)
            importVM.setModelContext(modelContext)
            segmentLibraryVM.setModelContext(modelContext)
            schemeVM.setModelContext(modelContext)
            updateChecker.checkSilently()
        }
        .onReceive(NotificationCenter.default.publisher(for: .mixCutNavigate)) { notification in
            if let item = notification.object as? NavigationItem {
                withAnimation(.easeOut(duration: 0.18)) {
                    selectedNavItem = item
                }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .mixCutNewProject)) { _ in
            projectVM.createProject()
        }
        .onReceive(NotificationCenter.default.publisher(for: .mixCutShowShortcuts)) { _ in
            showShortcuts = true
        }
        .onReceive(NotificationCenter.default.publisher(for: .mixCutDataDidUndo)) { _ in
            reloadAfterUndo()
        }
        .background(
            VStack(spacing: 0) {
                Button("") {
                    withAnimation(.easeOut(duration: 0.2)) {
                        sidebarVisible.toggle()
                    }
                }
                .keyboardShortcut("b", modifiers: .command)
                Button("") { showShortcuts = true }
                    .keyboardShortcut("/", modifiers: .command)
            }
            .opacity(0)
        )
        .sheet(isPresented: $showShortcuts) {
            KeyboardShortcutsSheet()
        }
        }   // close VStack (UpdateBanner + HStack)

        ToastOverlay()
        }
        .frame(minWidth: 900, minHeight: 600)
        .sheet(isPresented: Binding(
            get: { !hasCompletedOnboarding },
            set: { newValue in
                if !newValue { hasCompletedOnboarding = true }
            }
        )) {
            OnboardingView {
                hasCompletedOnboarding = true
            }
        }
    }

    /// 撤销 / 重做后重载当前数据。
    /// 全局单一撤销栈：⌘Z 可能回滚任意项目的改动，所以统一重建项目列表 +
    /// 重载持有自身快照数组（不随 SwiftData Observation 自动刷新）的各 VM。
    /// 复用「切换项目」同款 loadXXX(for:) 路径，遵守切换项目铁律。
    private func reloadAfterUndo() {
        // 1) 项目列表可能因删除/恢复项目而变化
        projectVM.fetchProjects()

        // 2) 当前选中项目若已被撤销删除（恢复了"删除项目"操作），从最新列表里取消选中
        if let selected = projectVM.selectedProject,
           !projectVM.projects.contains(where: { $0.id == selected.id }) {
            projectVM.selectedProject = nil
        }

        // 3) 重载当前项目下持有快照的 VM（ImportView 直接读 project.videos，靠 Observation 自动刷新，无需手动）
        guard let project = projectVM.selectedProject else { return }
        segmentLibraryVM.loadSegments(for: project)
        schemeVM.loadSchemes(for: project)
    }

    @ViewBuilder
    private func detailView(for project: Project) -> some View {
        switch selectedNavItem {
        case .overview:
            ProjectOverviewView(project: project, projectVM: projectVM, selectedNavItem: $selectedNavItem)
        case .importMedia:
            ImportView(project: project, importVM: importVM)
        case .segmentLibrary:
            SegmentLibraryView(project: project, viewModel: segmentLibraryVM, schemeVM: schemeVM)
        case .schemes:
            SchemeListView(project: project, viewModel: schemeVM, segmentLibraryVM: segmentLibraryVM)
        case .export:
            ExportView(project: project, schemeVM: schemeVM)
        case .none:
            ProjectOverviewView(project: project, projectVM: projectVM, selectedNavItem: $selectedNavItem)
        }
    }
}
