import Foundation
import AVFoundation
import Observation

/// 一条 BGM：文件即数据，name = 文件名，无数据库记录。
struct BGMTrack: Identifiable, Hashable, Sendable {
    let path: String
    let name: String
    let duration: Double   // 秒；0 = 时长未知（理论上不会发生，导入时已校验）
    var id: String { path }

    /// 时长的人话格式："3:25"；未知 → "--:--"
    var durationText: String {
        guard duration.isFinite, duration > 0 else { return "--:--" }
        let total = Int(duration.rounded())
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}

/// 全局 BGM 库：目录扫描 / 上传（校验 + 重名去重）/ 删除。
/// BGM 库页面和导出页共用。全项目共享（与视频素材的全局共享逻辑一致）。
@MainActor
@Observable
final class BGMLibraryStore {
    private(set) var tracks: [BGMTrack] = []

    /// 重新扫描 BGM 目录（文件名自然排序）。
    /// 时长逐个串行读取——BGM 库预期就是几十条的量级；若将来涨到数百条再并行化（TaskGroup）。
    func reload() async {
        let dir = FileHelper.bgmLibraryDirectory
        let files = (try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? []
        var list: [BGMTrack] = []
        for url in files.sorted(by: {
            $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending
        }) {
            let duration = await Self.audioDuration(url: url) ?? 0
            list.append(BGMTrack(path: url.path, name: url.lastPathComponent, duration: duration))
        }
        tracks = list
    }

    /// 导入音频文件：逐个校验是有效音频（AVFoundation 读得出音轨与时长），
    /// 无效/复制失败的**不静默吞掉**，逐条返回「文件名 + 人话原因」。
    func importFiles(urls: [URL]) async -> [(name: String, reason: String)] {
        var failures: [(name: String, reason: String)] = []
        var existing = Set(
            (try? FileManager.default.contentsOfDirectory(atPath: FileHelper.bgmLibraryDirectory.path)) ?? []
        )
        for url in urls {
            guard await Self.audioDuration(url: url) != nil else {
                failures.append((url.lastPathComponent, "不是有效的音频文件，或文件已损坏"))
                continue
            }
            // 磁盘空间预检：超大文件照单全收会把磁盘写满，拷贝前先比对目标卷剩余空间
            if let reason = Self.diskSpaceProblem(copying: url) {
                failures.append((url.lastPathComponent, reason))
                continue
            }
            let name = UniqueFileNamer.uniqueName(for: url.lastPathComponent, existing: existing)
            let dest = FileHelper.bgmLibraryDirectory.appendingPathComponent(name)
            do {
                try FileManager.default.copyItem(at: url, to: dest)
                existing.insert(name)
            } catch {
                MixLog.error("[BGM] 导入失败 \(url.lastPathComponent): \(error.localizedDescription)")
                failures.append((url.lastPathComponent, "复制文件失败：\(error.localizedDescription)"))
            }
        }
        await reload()
        return failures
    }

    /// 删除一条 BGM。返回 nil = 成功；非 nil = 人话失败原因。
    func delete(_ track: BGMTrack) async -> String? {
        do {
            try FileManager.default.removeItem(atPath: track.path)
        } catch {
            MixLog.error("[BGM] 删除失败 \(track.name): \(error.localizedDescription)")
            return "删除失败：\(error.localizedDescription)"
        }
        await reload()
        return nil
    }

    /// 拷贝该文件是否会把目标卷写满；有问题返回人话原因，没问题返回 nil。
    /// 预留 500MB 余量——磁盘被写到只剩几字节时系统本身就会异常。
    private static func diskSpaceProblem(copying url: URL) -> String? {
        let reserve: Int64 = 500 * 1024 * 1024
        guard let fileSize = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? Int64,
              let available = try? FileHelper.bgmLibraryDirectory.resourceValues(
                  forKeys: [.volumeAvailableCapacityForImportantUsageKey]
              ).volumeAvailableCapacityForImportantUsage else {
            return nil   // 读不到大小/剩余空间就不拦（拷贝失败自有 catch 兜底并透出原因）
        }
        if fileSize + reserve > available {
            let need = ByteCountFormatter.string(fromByteCount: fileSize, countStyle: .file)
            let have = ByteCountFormatter.string(fromByteCount: available, countStyle: .file)
            return "磁盘空间不足：该文件约 \(need)，当前磁盘仅剩 \(have)。请先清理磁盘"
        }
        return nil
    }

    /// 读音频时长；读不出（非音频 / 损坏 / 无音轨）返回 nil。
    private static func audioDuration(url: URL) async -> Double? {
        let asset = AVURLAsset(url: url)
        guard let audioTracks = try? await asset.loadTracks(withMediaType: .audio),
              !audioTracks.isEmpty,
              let duration = try? await asset.load(.duration) else { return nil }
        let seconds = CMTimeGetSeconds(duration)
        return seconds.isFinite && seconds > 0 ? seconds : nil
    }
}
