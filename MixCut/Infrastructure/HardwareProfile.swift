import Foundation

/// 主机硬件画像 — 检测芯片型号、核心数、内存、Media Engine 数等
///
/// 与 Windows 版的 HardwareEncoderProbe 概念对齐，但**针对 Apple Silicon 架构特化**：
/// - Apple Silicon 是 SoC，CPU + GPU + Media Engine 共享统一内存
/// - **Media Engine 是独立硬件单元**（VideoToolbox 直连），与 CPU/GPU 不抢资源
/// - 编码 1 路 1080p H.264 只占 ~5-10% CPU
/// - whisper.cpp 在 Apple Silicon 上自动用 Metal GPU 后端
///
/// 不照搬 Windows 公式（独立 NVIDIA 卡有多 NVENC session），因为 Apple Silicon 的 Media Engine 数量决定了
/// 并发编码上限，与 CPU 核数关系不大。
@MainActor
struct HardwareProfile {
    static let shared = HardwareProfile()

    /// 芯片家族
    enum ChipFamily: String {
        case intel = "Intel"
        case m1 = "M1", m2 = "M2", m3 = "M3", m4 = "M4"
        case unknownAppleSilicon = "Apple Silicon"
    }

    /// 芯片等级（决定 Media Engine 数）
    enum ChipTier {
        case base, pro, max, ultra, intel

        var displayName: String {
            switch self {
            case .base:  return ""
            case .pro:   return "Pro"
            case .max:   return "Max"
            case .ultra: return "Ultra"
            case .intel: return ""
            }
        }
    }

    let chipBrandString: String       // 原始字符串 "Apple M2 Pro" / "Intel Core i9..."
    let chipFamily: ChipFamily
    let chipTier: ChipTier
    let isAppleSilicon: Bool
    let physicalCores: Int            // 物理核心数（P+E 合计）
    let performanceCores: Int         // 性能核数
    let memoryGB: Int                 // 物理内存 GB
    let mediaEngineCount: Int         // Media Engine 数（影响并发编码上限）
    let videoToolboxAvailable: Bool   // ffmpeg -encoders 含 h264_videotoolbox
    let whisperBackend: String        // "Metal" / "CPU"

    /// 友好显示名 (例 "Apple M2 Pro")
    var chipDisplayName: String { chipBrandString }

    /// Media Engine 数说明
    var mediaEngineDescription: String {
        if !isAppleSilicon {
            return videoToolboxAvailable ? "1 (Intel Quick Sync)" : "无硬件加速"
        }
        switch mediaEngineCount {
        case 0: return "无（软件编码）"
        case 1: return chipTier == .pro ? "1 (Apple Silicon Pro)" : "1 (Apple Silicon base)"
        case 2: return "2 (Apple Silicon Max)"
        case 4: return "4 (Apple Silicon Ultra)"
        default: return "\(mediaEngineCount)"
        }
    }

    private init() {
        let brand = Self.sysctlString("machdep.cpu.brand_string") ?? "Unknown"
        self.chipBrandString = brand

        // 检测 Apple Silicon
        let isAS = Self.sysctlInt("hw.optional.arm64") == 1
        self.isAppleSilicon = isAS

        // 解析芯片家族 / 等级
        let (family, tier) = Self.parseChip(from: brand, isAppleSilicon: isAS)
        self.chipFamily = family
        self.chipTier = tier

        // 核心数
        self.physicalCores = Self.sysctlInt("hw.physicalcpu") ?? ProcessInfo.processInfo.processorCount
        // 性能核（Apple Silicon 才有区分）
        if isAS {
            self.performanceCores = Self.sysctlInt("hw.perflevel0.physicalcpu") ?? Self.sysctlInt("hw.physicalcpu") ?? 0
        } else {
            self.performanceCores = Self.sysctlInt("hw.physicalcpu") ?? ProcessInfo.processInfo.processorCount
        }

        // 内存（GB）
        let memBytes = Self.sysctlInt64("hw.memsize") ?? 0
        self.memoryGB = Int(memBytes / 1024 / 1024 / 1024)

        // Media Engine 数（按芯片型号映射）
        self.mediaEngineCount = Self.mediaEngineCount(family: family, tier: tier, isAppleSilicon: isAS)

        // VideoToolbox 可用性（macOS 上 Apple Silicon 必有，Intel 看具体 CPU 是否含 Quick Sync）
        self.videoToolboxAvailable = isAS || brand.contains("Intel")

        // Whisper 后端
        self.whisperBackend = isAS ? "Metal (Apple GPU)" : "CPU"
    }

    // MARK: - 芯片解析

    private static func parseChip(from brand: String, isAppleSilicon: Bool) -> (ChipFamily, ChipTier) {
        guard isAppleSilicon else {
            return (.intel, .intel)
        }
        // brand 示例: "Apple M2 Pro" / "Apple M3 Max" / "Apple M1 Ultra"
        let lower = brand.lowercased()
        let family: ChipFamily = {
            if lower.contains("m4") { return .m4 }
            if lower.contains("m3") { return .m3 }
            if lower.contains("m2") { return .m2 }
            if lower.contains("m1") { return .m1 }
            return .unknownAppleSilicon
        }()
        let tier: ChipTier = {
            if lower.contains("ultra") { return .ultra }
            if lower.contains("max") { return .max }
            if lower.contains("pro") { return .pro }
            return .base
        }()
        return (family, tier)
    }

    /// Apple Silicon Media Engine 数映射表
    /// 数据来源：Apple WWDC 与各芯片官方规格
    private static func mediaEngineCount(family: ChipFamily, tier: ChipTier, isAppleSilicon: Bool) -> Int {
        guard isAppleSilicon else { return 1 }   // Intel Quick Sync 1 路
        switch (family, tier) {
        case (.m1, .base):     return 1
        case (.m1, .pro):      return 1
        case (.m1, .max):      return 2
        case (.m1, .ultra):    return 4
        case (.m2, .base):     return 1
        case (.m2, .pro):      return 1
        case (.m2, .max):      return 2
        case (.m2, .ultra):    return 4
        case (.m3, .base):     return 1
        case (.m3, .pro):      return 1
        case (.m3, .max):      return 2
        case (.m4, .base):     return 1
        case (.m4, .pro):      return 1
        case (.m4, .max):      return 2
        default:               return 1   // 未知型号兜底
        }
    }

    // MARK: - sysctl 工具

    private static func sysctlString(_ name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buf = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &buf, &size, nil, 0) == 0 else { return nil }
        return String(cString: buf)
    }

    private static func sysctlInt(_ name: String) -> Int? {
        var value: Int32 = 0
        var size = MemoryLayout<Int32>.size
        guard sysctlbyname(name, &value, &size, nil, 0) == 0 else { return nil }
        return Int(value)
    }

    private static func sysctlInt64(_ name: String) -> Int64? {
        var value: Int64 = 0
        var size = MemoryLayout<Int64>.size
        guard sysctlbyname(name, &value, &size, nil, 0) == 0 else { return nil }
        return value
    }
}
