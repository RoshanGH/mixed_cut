import Foundation

/// 文件管理工具
enum FileHelper {

    /// 确保目录存在，失败时记录日志
    private static func ensureDirectory(at url: URL) {
        do {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        } catch {
            MixLog.error("无法创建目录 \(url.path): \(error.localizedDescription)")
        }
    }

    /// 应用沙盒中的项目数据目录
    static var appSupportDirectory: URL {
        guard let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            let fallback = FileManager.default.temporaryDirectory.appendingPathComponent("MixCut", isDirectory: true)
            ensureDirectory(at: fallback)
            return fallback
        }
        let url = base.appendingPathComponent("MixCut", isDirectory: true)
        ensureDirectory(at: url)
        return url
    }

    // MARK: - SwiftData 数据库

    /// MixCut 专属数据库文件路径。
    ///
    /// ⚠️ 必须用专属库名，**绝不能**用 SwiftData 默认库：非沙盒 App 的默认库固定落在
    /// `~/Library/Application Support/default.store`，会与本机其它非沙盒 SwiftData App
    /// 共用同一文件，schema 不符时双方互相清库，导致项目数据丢失。
    static var mixCutStoreURL: URL {
        appSupportDirectory.appendingPathComponent("MixCut.store")
    }

    /// 旧版共享数据库（SwiftData 默认库）路径
    static var legacyDefaultStoreURL: URL? {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("default.store")
    }

    // MARK: - 全局视频存储（按 hash 去重）

    /// 全局视频存储目录
    static var globalVideoDirectory: URL {
        let url = appSupportDirectory.appendingPathComponent("Videos", isDirectory: true)
        ensureDirectory(at: url)
        return url
    }

    /// 全局缩略图存储目录
    static var globalThumbnailDirectory: URL {
        let url = appSupportDirectory.appendingPathComponent("Thumbnails", isDirectory: true)
        ensureDirectory(at: url)
        return url
    }

    // MARK: - Whisper 语音模型存储

    /// Whisper 语音模型存储目录。
    ///
    /// ⚠️ 必须放在 Application Support，**绝不能**放 `~/Library/Caches`：
    /// macOS 把 Caches 当作「可重建缓存」，磁盘紧张 / 重启 / 系统维护时会主动清空，
    /// 而模型（ggml-large-v3-turbo ≈ 1.5GB）重下成本极高。曾因放 Caches 导致用户重启后模型丢失。
    static var whisperModelsDirectory: URL {
        let url = appSupportDirectory.appendingPathComponent("whisper-models", isDirectory: true)
        ensureDirectory(at: url)
        // 标记不参与备份：1.5GB 模型可随时重下，无需进 Time Machine / iCloud
        excludeFromBackup(url)
        return url
    }

    /// 旧版模型目录（`~/Library/Caches/com.mixcut.app/whisper-models`），仅用于一次性迁移读取
    static var legacyCacheWhisperModelsDirectory: URL? {
        guard let cacheDir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first else {
            return nil
        }
        return cacheDir.appendingPathComponent("com.mixcut.app/whisper-models", isDirectory: true)
    }

    /// 一次性迁移：把旧 Caches 目录里的 whisper 模型移动到 Application Support。
    /// 幂等，可安全多次调用；同卷 move 是元数据操作，1.5GB 也瞬间完成。
    static func migrateWhisperModelsToAppSupport() {
        let fm = FileManager.default
        guard let legacyDir = legacyCacheWhisperModelsDirectory,
              fm.fileExists(atPath: legacyDir.path) else { return }
        guard let entries = try? fm.contentsOfDirectory(at: legacyDir, includingPropertiesForKeys: nil) else { return }

        let destDir = whisperModelsDirectory
        // 同时迁移 .bin（完整模型）和 .bin.partial（断点续传临时文件），
        // 否则旧目录会残留最多 1.5GB 的 partial 文件，且续传进度丢失
        for src in entries where src.pathExtension == "bin" || src.pathExtension == "partial" {
            let dest = destDir.appendingPathComponent(src.lastPathComponent)
            if fm.fileExists(atPath: dest.path) {
                // 新目录已有同名文件，旧的直接删除回收空间
                try? fm.removeItem(at: src)
                continue
            }
            do {
                try fm.moveItem(at: src, to: dest)
                MixLog.info("已迁移 Whisper 模型文件到 Application Support: \(src.lastPathComponent)")
            } catch {
                MixLog.error("迁移 Whisper 模型文件失败 \(src.lastPathComponent): \(error.localizedDescription)")
            }
        }
        // 迁移后清理空的旧目录
        if let remaining = try? fm.contentsOfDirectory(atPath: legacyDir.path), remaining.isEmpty {
            try? fm.removeItem(at: legacyDir)
        }
    }

    /// 将目录标记为不参与备份（iCloud / Time Machine）。
    /// 幂等：已标记则直接跳过，避免每次访问目录都重复写元数据。
    private static func excludeFromBackup(_ url: URL) {
        var target = url
        // 已经标记过就不再重复设置（省去重复 syscall）
        if let already = try? target.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup,
           already {
            return
        }
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        do {
            try target.setResourceValues(values)
        } catch {
            MixLog.error("标记目录不参与备份失败 \(url.path): \(error.localizedDescription)")
        }
    }

    /// 拷贝视频文件到全局目录（按 hash 子目录存储，同一视频只保留一份）
    static func copyVideoToGlobal(from sourceURL: URL, contentHash: String) throws -> URL {
        let hashDir = globalVideoDirectory.appendingPathComponent(contentHash, isDirectory: true)
        ensureDirectory(at: hashDir)
        let destURL = hashDir.appendingPathComponent(sourceURL.lastPathComponent)

        // 文件已存在则跳过（同 hash 同文件名，内容一定相同）
        if FileManager.default.fileExists(atPath: destURL.path) {
            return destURL
        }
        try FileManager.default.copyItem(at: sourceURL, to: destURL)
        return destURL
    }

    /// 删除全局视频文件（当无任何项目引用时调用）
    static func deleteGlobalVideoFiles(localPath: String, thumbnailPath: String?) {
        let fm = FileManager.default
        if fm.fileExists(atPath: localPath) {
            // 删除文件
            try? fm.removeItem(atPath: localPath)
            // 尝试删除空的 hash 子目录
            let parentDir = (localPath as NSString).deletingLastPathComponent
            if let contents = try? fm.contentsOfDirectory(atPath: parentDir), contents.isEmpty {
                try? fm.removeItem(atPath: parentDir)
            }
        }
        if let thumbPath = thumbnailPath, fm.fileExists(atPath: thumbPath) {
            try? fm.removeItem(atPath: thumbPath)
        }
    }

    /// 临时文件目录
    static var tempDirectory: URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("MixCut", isDirectory: true)
        ensureDirectory(at: url)
        return url
    }

    /// 删除整个项目目录（早期按项目存储时的兼容清理；新数据走全局目录但此函数保留以彻底清空老目录）
    static func deleteProjectDirectory(for projectID: UUID) {
        let projectDir = appSupportDirectory
            .appendingPathComponent("Projects", isDirectory: true)
            .appendingPathComponent(projectID.uuidString, isDirectory: true)
        guard FileManager.default.fileExists(atPath: projectDir.path) else { return }
        do {
            try FileManager.default.removeItem(at: projectDir)
        } catch {
            MixLog.error("删除项目目录失败 \(projectID): \(error.localizedDescription)")
        }
    }
}
