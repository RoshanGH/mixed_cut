import SwiftUI
import SwiftData

/// 侧边栏导航项
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

    @State private var selectedNavItem: NavigationItem? = .overview

    var body: some View {
        HStack(spacing: 0) {
            // 侧边栏
            SidebarView(
                projectVM: projectVM,
                selectedNavItem: $selectedNavItem
            )
            .frame(width: 220)

            Divider()

            // 详情区域
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
        }
        .frame(minWidth: 900, minHeight: 600)
    }

    @ViewBuilder
    private func detailView(for project: Project) -> some View {
        switch selectedNavItem {
        case .overview:
            ProjectOverviewView(project: project, projectVM: projectVM, selectedNavItem: $selectedNavItem)
        case .importMedia:
            ImportView(project: project, importVM: importVM)
        case .segmentLibrary:
            SegmentLibraryView(project: project, viewModel: segmentLibraryVM)
        case .schemes:
            SchemeListView(project: project, viewModel: schemeVM, segmentLibraryVM: segmentLibraryVM)
        case .export:
            ExportView(project: project, schemeVM: schemeVM)
        case .none:
            ProjectOverviewView(project: project, projectVM: projectVM, selectedNavItem: $selectedNavItem)
        }
    }
}
