import SwiftUI
import SwiftData
import SQLite3
import AppKit

@main
struct MixCutApp: App {

    let modelContainer: ModelContainer
    private let initError: String?

    init() {
        // 强制浅色外观（AppKit + SwiftUI 同时生效）
        // 用 NSAppearance 设置而非 SwiftUI 的 .preferredColorScheme，
        // 后者只影响 SwiftUI 颜色环境，AppKit 嵌入的 NSTextField 仍读 system effectiveAppearance
        // 导致 NSColor.labelColor 在系统深色下返回白色，文字在浅色背景上完全不可见。
        DispatchQueue.main.async {
            NSApplication.shared.appearance = NSAppearance(named: .aqua)
        }

        do {
            let schema = Schema([
                Project.self,
                Video.self,
                Segment.self,
                MixStrategy.self,
                MixScheme.self,
                SchemeSegment.self,
                ProjectVideo.self,
            ])
            // 一次性迁移：旧版用共享的 default.store（会被其它非沙盒 App 清库），
            // 现改用专属库 MixCut.store。仅当旧库确实是 MixCut 的数据时才搬迁。
            Self.migrateDefaultStoreToDedicated()

            // 用专属库路径，彻底隔离，避免与其它 App 共用 default.store 互相清库
            let config = ModelConfiguration(schema: schema, url: FileHelper.mixCutStoreURL)
            modelContainer = try ModelContainer(for: schema, configurations: [config])
            initError = nil

            // 清除 bundle 内二进制的 quarantine 属性（DMG 分发后 macOS 会阻止执行）
            Self.removeQuarantineFromBundleBinaries()

            // 一次性迁移：把 Whisper 模型从旧 Caches 目录移到 Application Support
            // （Caches 会被系统清理，曾导致用户重启后模型丢失）
            FileHelper.migrateWhisperModelsToAppSupport()

            // 修复空的 semanticTypesData（旧数据迁移丢失）
            Self.fixMissingSemanticTypes(container: modelContainer)
            // 清洗已有台词中的乱码和多余空格
            Self.cleanExistingTranscripts(container: modelContainer)
            // 迁移旧版数据：Video.project → ProjectVideo 多对多
            Self.migrateToProjectVideoRelation(container: modelContainer)
            // 从磁盘恢复丢失的项目和视频（schema 变更后数据库被清空时）
            Self.recoverFromDisk(container: modelContainer)
            // 清理上次未正常完成的中间态视频（崩溃 / 强退 / 任务异常导致）
            Self.resetStaleAnalyzingStatus(container: modelContainer)
            // 为所有老项目补建"自定义组合"策略
            Self.ensureCustomGroupStrategy(container: modelContainer)
            // 重生所有 segment thumbnail 从中间帧→首帧（一次性后台迁移）
            let containerForMigration = modelContainer
            Task { await Self.regenerateSegmentThumbnailsToFirstFrame(container: containerForMigration) }
        } catch {
            // 数据库损坏时尝试内存模式启动，避免 fatalError 崩溃
            let schema = Schema([
                Project.self, Video.self, Segment.self,
                MixStrategy.self, MixScheme.self, SchemeSegment.self,
                ProjectVideo.self,
            ])
            let memConfig = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
            do {
                modelContainer = try ModelContainer(for: schema, configurations: [memConfig])
            } catch {
                // 内存模式也失败，使用最简配置
                modelContainer = try! ModelContainer(for: schema)
            }
            initError = "数据库初始化失败：\(error.localizedDescription)\n\n数据库文件可能损坏，当前使用临时模式运行（数据不会保存）。\n请删除 ~/Library/Application Support/MixCut/MixCut.store 后重启应用。"
        }
    }

    var body: some Scene {
        WindowGroup {
            if let errorMsg = initError {
                VStack(spacing: 16) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 48))
                        .foregroundStyle(.orange)
                    Text("数据库异常")
                        .font(.title2.bold())
                    Text(errorMsg)
                        .font(.body)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 40)
                    Button("复制错误信息") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(errorMsg, forType: .string)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding()
            } else {
                ContentView()
            }
        }
        .modelContainer(modelContainer)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("新建项目") {
                    NotificationCenter.default.post(name: .mixCutNewProject, object: nil)
                }
                .keyboardShortcut("n", modifiers: .command)
            }
            CommandGroup(after: .toolbar) {
                Button("项目概览") {
                    NotificationCenter.default.post(name: .mixCutNavigate, object: NavigationItem.overview)
                }
                .keyboardShortcut("1", modifiers: .command)
                Button("素材导入") {
                    NotificationCenter.default.post(name: .mixCutNavigate, object: NavigationItem.importMedia)
                }
                .keyboardShortcut("2", modifiers: .command)
                Button("分镜素材库") {
                    NotificationCenter.default.post(name: .mixCutNavigate, object: NavigationItem.segmentLibrary)
                }
                .keyboardShortcut("3", modifiers: .command)
                Button("混剪方案") {
                    NotificationCenter.default.post(name: .mixCutNavigate, object: NavigationItem.schemes)
                }
                .keyboardShortcut("4", modifiers: .command)
                Button("导出") {
                    NotificationCenter.default.post(name: .mixCutNavigate, object: NavigationItem.export)
                }
                .keyboardShortcut("5", modifiers: .command)
            }
        }

        Settings {
            SettingsView()
        }
    }

    // MARK: - 数据修复

    /// 为 semanticTypesData 为 NULL 的分镜填充默认值「过渡」
    /// 用户后续可通过"重新 AI 分析"获取正确的语义类型
    @MainActor
    private static func fixMissingSemanticTypes(container: ModelContainer) {
        // 避免每次启动都执行 SQL 查询
        let fixKey = "didFixMissingSemanticTypes_v1"
        if UserDefaults.standard.bool(forKey: fixKey) { return }

        guard let storeURL = container.configurations.first?.url else { return }

        var db: OpaquePointer?
        guard sqlite3_open(storeURL.path, &db) == SQLITE_OK else { return }
        defer { sqlite3_close(db) }

        // 统计需要修复的行数
        var countStmt: OpaquePointer?
        sqlite3_prepare_v2(db, "SELECT count(*) FROM ZSEGMENT WHERE ZSEMANTICTYPESDATA IS NULL", -1, &countStmt, nil)
        var nullCount: Int32 = 0
        if sqlite3_step(countStmt) == SQLITE_ROW {
            nullCount = sqlite3_column_int(countStmt, 0)
        }
        sqlite3_finalize(countStmt)

        guard nullCount > 0 else { return }

        // 编码默认值 ["过渡"]
        guard let defaultData = try? JSONEncoder().encode([SemanticType.transition]) else { return }

        let updateSQL = "UPDATE ZSEGMENT SET ZSEMANTICTYPESDATA = ? WHERE ZSEMANTICTYPESDATA IS NULL"
        var updateStmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, updateSQL, -1, &updateStmt, nil) == SQLITE_OK else { return }

        _ = defaultData.withUnsafeBytes { buffer in
            sqlite3_bind_blob(updateStmt, 1, buffer.baseAddress, Int32(defaultData.count), nil)
        }

        if sqlite3_step(updateStmt) == SQLITE_DONE {
            let affected = sqlite3_changes(db)
            MixLog.info(" 已为 \(affected) 个分镜填充默认语义类型「过渡」，请对相关视频执行「重新 AI 分析」获取正确类型")
        }
        sqlite3_finalize(updateStmt)

        UserDefaults.standard.set(true, forKey: fixKey)
    }

    /// 清洗已有分镜台词中的乱码（U+FFFD）和多余空格
    /// 同时清洗 Video.transcript 和 ASR 数据
    private static func cleanExistingTranscripts(container: ModelContainer) {
        let fixKey = "didCleanTranscripts_v1"
        if UserDefaults.standard.bool(forKey: fixKey) { return }

        let context = container.mainContext

        // 清洗 Segment.text
        let segDescriptor = FetchDescriptor<Segment>()
        if let segments = try? context.fetch(segDescriptor) {
            var fixedCount = 0
            for seg in segments {
                let original = seg.text
                let cleaned = cleanText(original)
                if cleaned != original {
                    seg.text = cleaned
                    fixedCount += 1
                }
            }
            if fixedCount > 0 {
                MixLog.info(" 已清洗 \(fixedCount) 个分镜的台词乱码")
            }
        }

        // 清洗 Video.transcript
        let videoDescriptor = FetchDescriptor<Video>()
        if let videos = try? context.fetch(videoDescriptor) {
            for video in videos {
                if let transcript = video.transcript {
                    let cleaned = cleanText(transcript)
                    if cleaned != transcript {
                        video.transcript = cleaned
                    }
                }
                // 清洗 ASR sentences
                var sentences = video.asrSentences
                var sentencesChanged = false
                for i in sentences.indices {
                    let cleaned = cleanText(sentences[i].text)
                    if cleaned != sentences[i].text {
                        sentences[i].text = cleaned
                        sentencesChanged = true
                    }
                }
                if sentencesChanged {
                    video.asrSentences = sentences
                }
            }
        }

        try? context.save()
        UserDefaults.standard.set(true, forKey: fixKey)
    }

    /// 清洗文本：移除 U+FFFD 乱码、合并连续空格
    private static func cleanText(_ text: String) -> String {
        var result = text
            .replacingOccurrences(of: "\u{FFFD}", with: "")
        while result.contains("  ") {
            result = result.replacingOccurrences(of: "  ", with: " ")
        }
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// 迁移旧版数据：为没有 ProjectVideo 关联的 Video 创建关联
    /// 旧版 Video 通过 SQLite 直接查 ZPROJECT 外键找到所属项目
    private static func migrateToProjectVideoRelation(container: ModelContainer) {
        let fixKey = "didMigrateProjectVideo_v1"
        if UserDefaults.standard.bool(forKey: fixKey) { return }

        let context = container.mainContext

        // 查找所有没有 ProjectVideo 关联的 Video
        let videoDescriptor = FetchDescriptor<Video>()
        guard let allVideos = try? context.fetch(videoDescriptor) else {
            UserDefaults.standard.set(true, forKey: fixKey)
            return
        }

        let orphanVideos = allVideos.filter { $0.projectVideos.isEmpty }
        guard !orphanVideos.isEmpty else {
            UserDefaults.standard.set(true, forKey: fixKey)
            return
        }

        // 通过 SQLite 查询旧的 Video→Project 外键关系
        guard let storeURL = container.configurations.first?.url else {
            UserDefaults.standard.set(true, forKey: fixKey)
            return
        }

        var db: OpaquePointer?
        guard sqlite3_open(storeURL.path, &db) == SQLITE_OK else {
            UserDefaults.standard.set(true, forKey: fixKey)
            return
        }
        defer { sqlite3_close(db) }

        // 查所有项目
        let projectDescriptor = FetchDescriptor<Project>()
        guard let allProjects = try? context.fetch(projectDescriptor) else {
            UserDefaults.standard.set(true, forKey: fixKey)
            return
        }

        // 建立 Z_PK → Project 的映射（SwiftData 内部用 Z_PK 作为行号）
        // 由于无法直接获取 Z_PK，使用 UUID 匹配
        var migratedCount = 0

        // 用 SQL 查询 ZVIDEO 表中的 ZPROJECT 外键
        // SwiftData 存储的外键列名通常是关系名大写
        var stmt: OpaquePointer?
        let sql = """
            SELECT v.ZIDENTIFIER, p.ZIDENTIFIER
            FROM ZVIDEO v
            LEFT JOIN ZPROJECT p ON v.ZPROJECT = p.Z_PK
            WHERE v.ZPROJECT IS NOT NULL
        """

        // 尝试查询（列名可能不同）
        if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
            // 建 UUID → Project 查找表
            var projectByUUID: [String: Project] = [:]
            for p in allProjects {
                projectByUUID[p.id.uuidString.uppercased()] = p
            }

            var videoByUUID: [String: Video] = [:]
            for v in orphanVideos {
                videoByUUID[v.id.uuidString.uppercased()] = v
            }

            while sqlite3_step(stmt) == SQLITE_ROW {
                guard let videoIDPtr = sqlite3_column_text(stmt, 0),
                      let projectIDPtr = sqlite3_column_text(stmt, 1) else { continue }

                let videoUUID = String(cString: videoIDPtr).uppercased()
                let projectUUID = String(cString: projectIDPtr).uppercased()

                if let video = videoByUUID[videoUUID], let project = projectByUUID[projectUUID] {
                    let pv = ProjectVideo(project: project, video: video)
                    context.insert(pv)
                    migratedCount += 1
                }
            }
            sqlite3_finalize(stmt)
        } else {
            // SQL 失败（可能列名不同），尝试用第一个项目兜底
            MixLog.info(" SQL 迁移查询失败，尝试将孤儿视频关联到第一个项目")
            if let firstProject = allProjects.first {
                for video in orphanVideos {
                    let pv = ProjectVideo(project: firstProject, video: video)
                    context.insert(pv)
                    migratedCount += 1
                }
            }
        }

        if migratedCount > 0 {
            try? context.save()
            MixLog.info(" 已迁移 \(migratedCount) 个视频到 ProjectVideo 关联")
        }

        UserDefaults.standard.set(true, forKey: fixKey)
    }

    /// 从磁盘恢复丢失的项目和视频
    /// 当 schema 变更导致数据库被清空时，扫描旧项目目录自动重建
    /// 清理上次未正常完成的中间态视频
    /// 启动时把所有处于 detectingScenes / transcribing / analyzing 的视频
    /// 标记为 failed 或 imported（取决于是否已有分镜数据），避免 UI 永久卡住"分析中"
    @MainActor
    private static func resetStaleAnalyzingStatus(container: ModelContainer) {
        let context = container.mainContext
        let descriptor = FetchDescriptor<Video>()
        guard let videos = try? context.fetch(descriptor) else { return }
        var fixedCount = 0
        for v in videos {
            switch v.status {
            case .queued, .detectingScenes, .transcribing, .analyzing:
                if v.segments.isEmpty {
                    v.status = .failed
                    v.errorMessage = (v.errorMessage ?? "") + "\n[启动重置] 上次未完成的分析任务被中断，请点击重试"
                } else {
                    v.status = .completed
                }
                fixedCount += 1
            default:
                break
            }
        }
        if fixedCount > 0 {
            try? context.save()
            MixLog.info(" 启动时已重置 \(fixedCount) 个卡在中间态的视频状态")
        }
    }

    /// 为所有现有项目补上"自定义组合"策略容器（首次升级后执行一次）
    /// 新项目走 ProjectViewModel.createProject 同步创建，老项目走这里补
    @MainActor
    private static func ensureCustomGroupStrategy(container: ModelContainer) {
        let fixKey = "didEnsureCustomGroupStrategy_v1"
        if UserDefaults.standard.bool(forKey: fixKey) { return }

        let context = container.mainContext
        let descriptor = FetchDescriptor<Project>()
        guard let projects = try? context.fetch(descriptor) else { return }

        var addedCount = 0
        for project in projects {
            let hasCustomGroup = project.strategies.contains { $0.isCustomGroup }
            if !hasCustomGroup {
                let strategy = MixStrategy(
                    name: "自定义组合",
                    style: "",
                    description: "手动挑选分镜组合的方案",
                    targetAudience: "",
                    narrativeStructure: "",
                    targetDuration: 0
                )
                strategy.isCustomGroup = true
                strategy.project = project
                project.strategies.append(strategy)
                context.insert(strategy)
                addedCount += 1
            }
        }

        if addedCount > 0 {
            try? context.save()
            MixLog.info(" 已为 \(addedCount) 个老项目补建「自定义组合」策略")
        }

        UserDefaults.standard.set(true, forKey: fixKey)
    }

    /// 一次性迁移：把 segment thumbnail 从「中间帧」重新生成为「首帧」
    /// 修复历史 bug: ImportViewModel 早期版本用 (start+end)/2 作为缩略图时间点，与用户「分镜首帧」直觉不符
    @MainActor
    private static func regenerateSegmentThumbnailsToFirstFrame(container: ModelContainer) async {
        let fixKey = "didRegenerateSegmentThumbnailsToFirstFrame_v1"
        if UserDefaults.standard.bool(forKey: fixKey) { return }

        let context = container.mainContext
        let descriptor = FetchDescriptor<Segment>()
        guard let segments = try? context.fetch(descriptor), !segments.isEmpty else {
            UserDefaults.standard.set(true, forKey: fixKey)
            return
        }

        struct Job: Sendable {
            let segmentID: UUID
            let videoPath: String
            let firstFrameTime: Double
            let outputPath: String
        }

        let thumbDir = FileHelper.globalThumbnailDirectory
        var jobs: [Job] = []
        var segmentByID: [UUID: Segment] = [:]

        for segment in segments {
            guard let video = segment.video,
                  FileManager.default.fileExists(atPath: video.localPath) else { continue }
            if let oldPath = segment.thumbnailPath {
                try? FileManager.default.removeItem(atPath: oldPath)
            }
            let firstFrameTime = max(0, segment.startTime + 0.1)
            let outputPath = thumbDir.appendingPathComponent("seg_\(segment.id.uuidString).jpg").path
            jobs.append(Job(
                segmentID: segment.id,
                videoPath: video.localPath,
                firstFrameTime: firstFrameTime,
                outputPath: outputPath
            ))
            segmentByID[segment.id] = segment
        }

        guard !jobs.isEmpty else {
            UserDefaults.standard.set(true, forKey: fixKey)
            return
        }

        MixLog.info(" 开始重生 \(jobs.count) 个分镜缩略图（中间帧 → 首帧）")

        let ffmpeg = FFmpegRunner()
        let results: [(UUID, String?)] = await withTaskGroup(of: (UUID, String?).self) { group in
            for job in jobs {
                group.addTask { [ffmpeg] in
                    do {
                        try await ffmpeg.generateThumbnail(
                            from: job.videoPath,
                            at: job.firstFrameTime,
                            to: job.outputPath
                        )
                        return (job.segmentID, job.outputPath)
                    } catch {
                        return (job.segmentID, nil)
                    }
                }
            }
            var out: [(UUID, String?)] = []
            for await r in group { out.append(r) }
            return out
        }

        var successCount = 0
        for (id, path) in results {
            if let segment = segmentByID[id], let path {
                segment.thumbnailPath = path
                successCount += 1
            }
        }
        try? context.save()
        ThumbnailCache.shared.clear()

        MixLog.info(" 完成重生 \(successCount)/\(jobs.count) 个分镜缩略图")
        UserDefaults.standard.set(true, forKey: fixKey)
    }

    /// 一次性迁移：把旧版共享的 default.store 搬到 MixCut 专属库。
    ///
    /// 背景：非沙盒 App 不指定库名时，SwiftData 默认库都落在共享路径
    /// `~/Library/Application Support/default.store`，会被本机其它非沙盒 SwiftData App
    /// 共用，schema 不符时互相清库导致数据丢失。改用专属库后需把老用户数据搬过去。
    ///
    /// 安全保证：仅当专属库尚不存在、且旧库确实含 MixCut 的 ZPROJECT 表时才搬迁，
    /// 避免把其它 App 的库误搬进来。连 -wal/-shm 一起复制，防止 WAL 中未合并数据丢失。
    private static func migrateDefaultStoreToDedicated() {
        let fm = FileManager.default
        let dest = FileHelper.mixCutStoreURL

        // 专属库已存在 → 已迁移过（或全新安装直接用新库），跳过
        if fm.fileExists(atPath: dest.path) { return }
        guard let legacy = FileHelper.legacyDefaultStoreURL,
              fm.fileExists(atPath: legacy.path) else { return }

        // 旧库必须确实是 MixCut 的库（含 ZPROJECT 表）才迁移
        guard sqliteHasTable(at: legacy.path, table: "ZPROJECT") else {
            MixLog.info("default.store 不含 MixCut 数据（可能被其它 App 占用），跳过迁移，使用全新专属库")
            return
        }

        // 先复制主库；失败则清理残留并 return，下次启动干净重试。
        // 关键：绝不能留下截断的主库文件——否则下次启动 fileExists 为 true 被误判
        // "已迁移"，SwiftData 打开损坏库进入内存模式，用户数据看似全丢。
        do {
            try fm.copyItem(at: legacy, to: dest)
        } catch {
            MixLog.error("迁移主数据库失败，已回滚残留，下次启动重试: \(error.localizedDescription)")
            for suffix in ["", "-wal", "-shm"] {
                try? fm.removeItem(atPath: dest.path + suffix)
            }
            return
        }

        // 主库已就位，再复制 WAL/SHM 保留未合并数据。这两个失败可容忍（SwiftData 会重建），
        // 此时主库已是完整状态，不影响数据安全。
        for suffix in ["-wal", "-shm"] {
            let src = URL(fileURLWithPath: legacy.path + suffix)
            guard fm.fileExists(atPath: src.path) else { continue }
            do {
                try fm.copyItem(at: src, to: URL(fileURLWithPath: dest.path + suffix))
            } catch {
                MixLog.error("迁移数据库 \(suffix) 失败（可容忍）: \(error.localizedDescription)")
            }
        }
        MixLog.info("已把 default.store 迁移到专属库 MixCut.store")
    }

    /// 用 SQLite C API 只读检查某 sqlite 文件是否含指定表。
    /// 不经 SwiftData 打开，避免 schema 不符时被清库。
    private static func sqliteHasTable(at path: String, table: String) -> Bool {
        var db: OpaquePointer?
        guard sqlite3_open_v2(path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
            sqlite3_close(db)
            return false
        }
        defer { sqlite3_close(db) }

        // table 为代码内常量（"ZPROJECT"）；额外做标识符白名单校验，杜绝任何注入可能
        guard table.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" }) else { return false }
        let sql = "SELECT 1 FROM sqlite_master WHERE type='table' AND name='\(table)' LIMIT 1"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return false }
        defer { sqlite3_finalize(stmt) }
        return sqlite3_step(stmt) == SQLITE_ROW
    }

    /// 清除 bundle 内 FFmpeg/whisper 二进制及 dylib 的 quarantine 属性
    /// DMG 分发后 macOS 会给所有文件打上 com.apple.quarantine，导致 ad-hoc 签名的二进制无法执行
    private static func removeQuarantineFromBundleBinaries() {
        guard let binURL = Bundle.main.resourceURL?.appendingPathComponent("bin") else { return }
        let binPath = binURL.path
        guard FileManager.default.fileExists(atPath: binPath) else { return }

        // 用 xattr -cr 递归清除整个 bin 目录的 quarantine
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/xattr")
        process.arguments = ["-cr", binPath]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            MixLog.error("清除 quarantine 失败: \(error)")
        }
    }

    private static func recoverFromDisk(container: ModelContainer) {
        let fixKey = "didRecoverFromDisk_v1"
        if UserDefaults.standard.bool(forKey: fixKey) { return }

        let context = container.mainContext

        // 检查数据库是否为空
        let projectDesc = FetchDescriptor<Project>()
        let existingProjects = (try? context.fetch(projectDesc)) ?? []
        if !existingProjects.isEmpty {
            // 数据库有数据，不需要恢复
            UserDefaults.standard.set(true, forKey: fixKey)
            return
        }

        // 扫描旧项目目录
        let projectsDir = FileHelper.appSupportDirectory
            .appendingPathComponent("Projects", isDirectory: true)
        guard let projectDirs = try? FileManager.default.contentsOfDirectory(
            at: projectsDir,
            includingPropertiesForKeys: nil
        ) else {
            UserDefaults.standard.set(true, forKey: fixKey)
            return
        }

        // 收集所有去重的视频文件路径（按文件名去重）
        var uniqueVideos: [String: URL] = [:]  // fileName → URL
        var projectVideoMap: [String: [String]] = [:]  // projectDirName → [fileName]

        for dir in projectDirs {
            let dirName = dir.lastPathComponent
            guard dirName != ".DS_Store" else { continue }

            let videosDir = dir.appendingPathComponent("Videos")
            guard let files = try? FileManager.default.contentsOfDirectory(
                at: videosDir,
                includingPropertiesForKeys: nil
            ) else { continue }

            let videoFiles = files.filter { url in
                let ext = url.pathExtension.lowercased()
                return ["mp4", "mov", "avi", "mkv", "m4v"].contains(ext)
            }

            if !videoFiles.isEmpty {
                projectVideoMap[dirName] = videoFiles.map(\.lastPathComponent)
                for file in videoFiles {
                    if uniqueVideos[file.lastPathComponent] == nil {
                        uniqueVideos[file.lastPathComponent] = file
                    }
                }
            }
        }

        guard !uniqueVideos.isEmpty else {
            UserDefaults.standard.set(true, forKey: fixKey)
            return
        }

        MixLog.info(" 发现 \(uniqueVideos.count) 个视频文件，开始恢复...")

        // 创建一个恢复项目
        let project = Project(name: "恢复的项目")
        project.status = .ready
        context.insert(project)

        // 为每个唯一视频创建 Video 实体
        for (fileName, fileURL) in uniqueVideos {
            let video = Video(name: fileName, localPath: fileURL.path)
            video.status = .imported  // 需要重新分析
            video.contentHash = ImportViewModel.computeFileHash(path: fileURL.path)
            context.insert(video)

            let pv = ProjectVideo(project: project, video: video)
            context.insert(pv)
        }

        try? context.save()
        MixLog.info(" 已恢复 \(uniqueVideos.count) 个视频到「恢复的项目」，请重新执行 AI 分析")

        UserDefaults.standard.set(true, forKey: fixKey)
    }
}
