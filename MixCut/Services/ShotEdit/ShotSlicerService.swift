import Foundation

/// 对一条逻辑分镜跑画面变化度检测，切出有序物理镜头帧区间（纯数据）。
/// 落库（创建 PhysicalShot）由调用方在 @MainActor 完成。
actor ShotSlicerService {
    private let sceneDetector: SceneDetectionService

    init(sceneDetector: SceneDetectionService = SceneDetectionService()) {
        self.sceneDetector = sceneDetector
    }

    /// - Parameters:
    ///   - videoPath: 源视频路径
    ///   - segmentStart/segmentEnd: 逻辑分镜时间窗口（秒）
    ///   - fps: 源视频帧率
    /// - Returns: 有序 `ShotRange`（源视频绝对帧号区间）
    func computeShots(videoPath: String,
                      segmentStart: Double,
                      segmentEnd: Double,
                      fps: Double,
                      sceneThreshold: Double = 0.3) async throws -> [ShotRange] {
        let boundaries = try await sceneDetector.detectScenes(in: videoPath, threshold: sceneThreshold)
        let cuts = boundaries.map { ShotCut(time: $0.time) }
        return ShotSegmentationEngine.split(
            segmentStart: segmentStart,
            segmentEnd: segmentEnd,
            sceneCuts: cuts,
            fps: fps
        )
    }
}
