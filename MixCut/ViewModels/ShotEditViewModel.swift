import Foundation
import SwiftData

/// 分镜头替换工作区的 VM：切分镜头 / 帧级微调 / 生成变体 / 占位选择 / 就地替换画面。
@MainActor
@Observable
final class ShotEditViewModel {
    // 服务
    private let slicer: ShotSlicerService
    private let variantService: ShotVariantService
    private let compositionService: ShotCompositionService

    // 可观察状态
    var shots: [PhysicalShot] = []                 // 当前分镜的分镜头（按 orderIndex 升序）
    var selections: [Int: SlotChoice] = [:]        // orderIndex -> 选定版本（默认 original）
    var busyVariantIDs: Set<UUID> = []             // 正在生成的变体 id（防重入 + UI 转圈）
    var progress: [UUID: String] = [:]             // 变体 id -> 状态文案
    var isSlicing = false
    var isComposing = false
    var errorMessage: String?
    var playingID: UUID?                            // 当前在播卡片（工作区本地单播协调）
    private var boundaryDirty = false               // 拖动边界是否真的动过（松手才提交）

    init(slicer: ShotSlicerService = ShotSlicerService(),
         variantService: ShotVariantService = ShotVariantService(),
         compositionService: ShotCompositionService = ShotCompositionService()) {
        self.slicer = slicer
        self.variantService = variantService
        self.compositionService = compositionService
    }

    // MARK: - 加载 / 切分镜头

    /// 进入工作区：已切过直接展示；没切过则按需切分并持久化。
    func loadShots(for segment: Segment, modelContext: ModelContext) async {
        errorMessage = nil
        let existing = segment.physicalShots.sorted { $0.orderIndex < $1.orderIndex }
        if !existing.isEmpty {
            shots = existing
            reconcileStaleGenerating(in: existing, modelContext: modelContext)
            loadSelectionsFromShots()
            await ensureShotThumbnails(segment: segment, modelContext: modelContext)
            return
        }
        guard let video = segment.video, video.fps > 0 else {
            errorMessage = "该分镜缺少视频/帧率信息，无法切分镜头"
            return
        }
        isSlicing = true
        defer { isSlicing = false }
        do {
            let ranges = try await slicer.computeShots(
                videoPath: video.localPath,
                segmentStart: segment.startTime,
                segmentEnd: segment.endTime,
                fps: video.fps
            )
            for r in ranges {
                let shot = PhysicalShot(orderIndex: r.orderIndex, startFrame: r.startFrame, endFrame: r.endFrame)
                shot.parentSegment = segment
                modelContext.insert(shot)
            }
            try? modelContext.save()
            shots = segment.physicalShots.sorted { $0.orderIndex < $1.orderIndex }
            loadSelectionsFromShots()
            await ensureShotThumbnails(segment: segment, modelContext: modelContext)
        } catch {
            errorMessage = "分镜头切分失败：\(error.localizedDescription)"
        }
    }

    /// 对账「僵尸生成中」变体。
    ///
    /// `generating` 状态是落库的，但轮询任务活在本 VM 里：一旦用户关掉工作区或退出 App，
    /// 轮询就没了，而变体会**永远停在转圈状态且没有任何操作按钮**（`.generating` 分支不给按钮），
    /// 用户只能删掉它 —— 可它很可能已经在云端跑成功并且**已经扣过费**。
    ///
    /// 这里在进入工作区时对账：凡是 `generating` 但当前并无活跃轮询的，一律降级为 `timedOut`。
    /// `timedOut` 已有完整的「重试（凭 taskId 取回结果，不重复扣费）」路径，一步接回既有能力。
    private func reconcileStaleGenerating(in shots: [PhysicalShot], modelContext: ModelContext) {
        var changed = 0
        for shot in shots {
            for variant in shot.variants where variant.status == .generating {
                // ⚠️ 必须查**进程级**注册表，不能只查本 VM 的 busyVariantIDs：
                // 工作区 sheet 每次弹出都会新建一个 ShotEditViewModel，而上一个 VM 发起的轮询
                // Task 在 sheet 关闭后仍在后台跑。只看本 VM 会把"其实正在正常轮询"的变体
                // 误判成超时并落库，用户此时点重试还会与旧任务并发写同一条记录。
                guard !ShotVariantPollRegistry.shared.isPolling(variant.id) else { continue }
                // 按有无 taskId 分流，确保每种状态都落到一个**可用**的按钮上：
                // - 有 taskId → timedOut：「重试」= 凭任务号取回结果，不重复扣费
                // - 无 taskId → failed：「重试」= 重新提交（此前根本没提交成功，未扣费）
                if let tid = variant.taskId, !tid.isEmpty {
                    variant.status = .timedOut
                    variant.friendlyError = "上次等待被中断（关闭了工作区或退出 App）。任务可能已在云端完成，点「重试」取回结果，不会重复扣费。"
                } else {
                    variant.status = .failed
                    variant.friendlyError = "上次生成被中断，未拿到任务号（未扣费）。点「重试」重新发起。"
                }
                changed += 1
            }
        }
        if changed > 0 {
            try? modelContext.save()
            MixLog.info("[ShotEditDiag] 对账僵尸生成中变体 \(changed) 个 → 已转为「已超时」，可重试取回")
        }
    }

    /// 从持久化的 PhysicalShot.selectedVariantID 恢复选择状态（重开工作区/调整后保持）。
    private func loadSelectionsFromShots() {
        var sel: [Int: SlotChoice] = [:]
        for s in shots {
            if let vid = s.selectedVariantID,
               s.variants.contains(where: { $0.id == vid && $0.status == .completed }) {
                sel[s.orderIndex] = .variant(vid)
            } else {
                sel[s.orderIndex] = .original
            }
        }
        selections = sel
    }

    /// 为缺缩略图的分镜头生成首帧缩略图（原画面），让轨道可预览。
    private func ensureShotThumbnails(segment: Segment, modelContext: ModelContext) async {
        guard let video = segment.video, video.fps > 0, let hash = video.contentHash else { return }
        let ffmpeg = FFmpegRunner()
        for shot in shots {
            let existingOK = shot.thumbnailPath.map { FileManager.default.fileExists(atPath: $0) } ?? false
            if existingOK { continue }
            let url = FileHelper.shotThumbnailURL(videoHash: hash, shotId: shot.id)
            let at = Double(shot.startFrame) / video.fps
            do {
                try await ffmpeg.generateThumbnail(from: video.localPath, at: at, to: url.path)
                shot.thumbnailPath = url.path
                // 固定路径重生成：清掉可能存在的「解码失败」记录，否则新图不会被读取
                ThumbnailCache.shared.invalidate(path: url.path)
            } catch { /* 缩略图失败不阻塞，保留占位 */ }
        }
        try? modelContext.save()
        // 触发视图刷新（缩略图路径已更新）
        shots = segment.physicalShots.sorted { $0.orderIndex < $1.orderIndex }
    }

    // MARK: - 帧级微调

    private func currentSpans() -> [ShotSpan] {
        shots.sorted { $0.orderIndex < $1.orderIndex }.map { ShotSpan(startFrame: $0.startFrame, endFrame: $0.endFrame) }
    }

    /// 合并 i 与 i+1（改变镜头数 → applyPartition）
    func mergeShots(at i: Int, segment: Segment, modelContext: ModelContext) {
        let result = ShotPartitionEditor.merge(currentSpans(), at: i)
        guard result != currentSpans() else {
            errorMessage = "这两个镜头无法合并（可能已经是同一个镜头，或索引越界）。"
            return
        }
        applyPartition(result, segment: segment, modelContext: modelContext)
    }
    /// 中点拆分镜头 i
    func splitShot(at i: Int, segment: Segment, modelContext: ModelContext) {
        let result = ShotPartitionEditor.splitAtMidpoint(currentSpans(), at: i)
        // ⚠️ `splitAtMidpoint` 在镜头太短时会原样返回，`applyPartition` 又会 no-op 早返回，
        // 于是按钮点下去**什么都不发生、也没有任何提示**，用起来就像按钮坏了。
        guard result != currentSpans() else {
            errorMessage = "这个镜头太短，拆开后每段不足最小长度，无法再拆分。"
            return
        }
        applyPartition(result, segment: segment, modelContext: modelContext)
    }

    /// 删掉某镜头名下所有变体的落盘文件，返回**已完成（即已计费出片）**的变体数量。
    /// 合并/拆分/移动边界都会作废这些变体，三处必须行为一致。
    @discardableResult
    private func purgeVariantFiles(of shot: PhysicalShot) -> Int {
        var completed = 0
        for v in shot.variants {
            if v.status == .completed { completed += 1 }
            if let p = v.resultVideoPath { try? FileManager.default.removeItem(atPath: p) }
            if let t = v.thumbnailPath { try? FileManager.default.removeItem(atPath: t) }
        }
        return completed
    }

    /// 明确告知用户「刚才那一下丢掉了几个已生成的画面替换」。
    /// 这些是按次计费生成出来的，静默销毁最不能接受——用户往往是误点了那个无边框小图标。
    private func notifyDiscardedVariants(_ count: Int) {
        guard count > 0 else { return }
        ToastCenter.shared.show(
            "调整镜头切分已丢弃 \(count) 个已生成的替换画面（需要的话要重新生成，会重新计费）",
            icon: "exclamationmark.triangle.fill", style: .warning, duration: 6)
    }

    /// 分区对账（按 (start,end) 相等保留，否则删/建）+ no-op 早返回 + 作废替换画面。
    private func applyPartition(_ newSpans: [ShotSpan], segment: Segment, modelContext: ModelContext) {
        guard newSpans != currentSpans() else { return }   // no-op：不误清替换画面
        let old = segment.physicalShots
        var reused = Set<UUID>()
        for (idx, span) in newSpans.enumerated() {
            if let match = old.first(where: { $0.startFrame == span.startFrame && $0.endFrame == span.endFrame && !reused.contains($0.id) }) {
                match.orderIndex = idx + 1
                reused.insert(match.id)
            } else {
                let s = PhysicalShot(orderIndex: idx + 1, startFrame: span.startFrame, endFrame: span.endFrame)
                s.parentSegment = segment
                modelContext.insert(s)
            }
        }
        // ⚠️ 删镜头前必须先删它名下变体的**磁盘文件**。
        // 只 delete(o) 靠 cascade 清数据库记录的话，几十 MB 的结果 mp4 会永远留在盘上、
        // 再也没人引用得到（endBoundaryEdit 是删文件的，这里以前漏了，行为不一致）。
        var discardedCount = 0
        for o in old where !reused.contains(o.id) {
            discardedCount += purgeVariantFiles(of: o)
            modelContext.delete(o)
        }
        segment.invalidateReplacedPicture()
        try? modelContext.save()
        notifyDiscardedVariants(discardedCount)
        shots = segment.physicalShots.sorted { $0.orderIndex < $1.orderIndex }
        loadSelectionsFromShots()
        Task { await ensureShotThumbnails(segment: segment, modelContext: modelContext) }
    }

    /// 拖动中：就地把第 b 个切分点移到 f（保持 PhysicalShot 身份，不落库）。
    func dragBoundary(boundaryIndex b: Int, toFrame f: Int) {
        let sorted = shots.sorted { $0.orderIndex < $1.orderIndex }
        guard b >= 0, b + 1 < sorted.count else { return }
        let spans = ShotPartitionEditor.moveBoundary(
            sorted.map { ShotSpan(startFrame: $0.startFrame, endFrame: $0.endFrame) },
            boundaryIndex: b, toFrame: f)
        let nf = spans[b].endFrame
        guard nf != sorted[b].endFrame else { return }   // 已到 clamp → 不脏
        sorted[b].endFrame = nf
        sorted[b + 1].startFrame = nf
        boundaryDirty = true
        shots = sorted
    }

    /// 松手 / ±帧后提交：对动过的两镜头失效变体、作废替换画面、重生缩略图。
    func endBoundaryEdit(boundaryIndex b: Int, segment: Segment, modelContext: ModelContext) {
        guard boundaryDirty else { return }
        boundaryDirty = false
        let sorted = shots.sorted { $0.orderIndex < $1.orderIndex }
        var discardedCount = 0
        for idx in [b, b + 1] where idx >= 0 && idx < sorted.count {
            let s = sorted[idx]
            discardedCount += purgeVariantFiles(of: s)
            for v in s.variants { modelContext.delete(v) }
            s.selectedVariantID = nil
            s.thumbnailPath = nil
        }
        segment.invalidateReplacedPicture()
        try? modelContext.save()
        notifyDiscardedVariants(discardedCount)
        shots = segment.physicalShots.sorted { $0.orderIndex < $1.orderIndex }
        loadSelectionsFromShots()
        Task { await ensureShotThumbnails(segment: segment, modelContext: modelContext) }
    }

    /// ±帧微调第 b 个切分点（一次性提交）
    func nudgeBoundary(boundaryIndex b: Int, deltaFrames: Int, segment: Segment, modelContext: ModelContext) {
        let sorted = shots.sorted { $0.orderIndex < $1.orderIndex }
        guard b >= 0, b + 1 < sorted.count else { return }
        dragBoundary(boundaryIndex: b, toFrame: sorted[b].endFrame + deltaFrames)
        endBoundaryEdit(boundaryIndex: b, segment: segment, modelContext: modelContext)
    }

    /// 分镜头时长（秒）
    func duration(of shot: PhysicalShot, fps: Double) -> Double {
        fps > 0 ? Double(shot.frameCount) / fps : 0
    }

    /// 是否可编辑（时长在 [2,10]）
    func isEditable(_ shot: PhysicalShot, fps: Double) -> Bool {
        ShotEditRules.isEditable(durationSeconds: duration(of: shot, fps: fps))
    }

    func ineligibleReason(_ shot: PhysicalShot, fps: Double) -> String? {
        ShotEditRules.ineligibleReason(durationSeconds: duration(of: shot, fps: fps))
    }

    // MARK: - 生成变体

    /// 首次生成：新建占位变体 → 提交拿 taskId 立即落库 → 轮询到终局。
    func generateVariant(shot: PhysicalShot, prompt: String, segment: Segment, modelContext: ModelContext) async {
        errorMessage = nil
        let trimmed = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { errorMessage = "请输入提示词"; return }

        // ⚠️ 防重复提交：每次提交都是一次真实计费。
        // 这里**不能**靠 `busyVariantIDs` —— 那是按 variant.id 记的，而本方法每次都新建一个变体，
        // 所以连点两下会拿到两个不同 id，防重入形同虚设，用户被扣两次钱。
        // 改为按「同一镜头 + 同一提示词 + 正在生成」判重。
        if shot.variants.contains(where: { $0.status == .generating && $0.prompt == trimmed }) {
            errorMessage = "这条提示词正在生成中，请勿重复提交（每次提交都会计费）"
            return
        }
        guard let (video, hash) = validatedVideo(shot: shot, segment: segment) else { return }

        let variant = ShotVariant(prompt: trimmed)
        variant.status = .generating
        variant.shot = shot
        modelContext.insert(variant)
        try? modelContext.save()

        await runGenerate(variant: variant, shot: shot, video: video, hash: hash,
                          prompt: trimmed, modelContext: modelContext)
    }

    /// 重新生成：复用同一个占位记录，发起**一次新任务**（会产生新 taskId、会计费）。
    /// 用于「提交阶段失败(无 taskId，之前没扣费)」与「阿里 FAILED / 结果过期(有 taskId 但旧结果拿不回)」。
    func regenerate(_ variant: ShotVariant, shot: PhysicalShot, segment: Segment, modelContext: ModelContext) async {
        errorMessage = nil
        guard !busyVariantIDs.contains(variant.id) else { return }
        guard let (video, hash) = validatedVideo(shot: shot, segment: segment) else { return }

        // 清掉旧任务痕迹：旧 taskId 已废（失败/过期），新任务从头来
        variant.taskId = nil
        variant.friendlyError = nil
        variant.status = .generating
        try? modelContext.save()

        await runGenerate(variant: variant, shot: shot, video: video, hash: hash,
                          prompt: variant.prompt, modelContext: modelContext)
    }

    /// 超时重试：**只用已有 taskId 查旧任务**，绝不重新提交、不扣费。
    /// 查到仍在跑 → 自动续查到本轮上限；查到成功 → 直接下载落地。
    func retryFetch(_ variant: ShotVariant, shot: PhysicalShot, segment: Segment, modelContext: ModelContext) async {
        errorMessage = nil
        guard !busyVariantIDs.contains(variant.id) else { return }
        guard let taskId = variant.taskId, !taskId.isEmpty else {
            // 理论不该发生（timedOut 一定有 taskId）；兜底提示
            errorMessage = "该占位缺少任务号，无法查询，请重新生成"; return
        }
        guard let (_, hash) = validatedVideo(shot: shot, segment: segment) else { return }

        let vid = variant.id
        variant.status = .generating          // 展示「云端生成中」并自动续查
        try? modelContext.save()
        busyVariantIDs.insert(vid)
        // 同时登记到进程级注册表：本 VM 可能被销毁（sheet 关闭），但轮询 Task 还在跑，
        // 下一个 VM 靠这个注册表才知道"有人正在轮询"，不会误判为僵尸。
        ShotVariantPollRegistry.shared.begin(vid)
        progress[vid] = "生成中"
        defer {
            busyVariantIDs.remove(vid)
            ShotVariantPollRegistry.shared.end(vid)
            progress[vid] = nil
        }

        do {
            let outcome = try await variantService.resume(
                taskId: taskId, videoHash: hash, shotId: shot.id, variantId: vid,
                onStatus: { [weak self] s in Task { @MainActor in self?.progress[vid] = s } }
            )
            apply(outcome, to: variant, modelContext: modelContext)
        } catch {
            // 网络抖动等：保持「已超时」，让用户可再次重试（taskId 仍在）
            variant.status = .timedOut
            try? modelContext.save()
            errorMessage = "查询任务失败：\(FriendlyError.reason(for: error))"
        }
    }

    // MARK: - 生成/重生成公共流程

    private func runGenerate(variant: ShotVariant, shot: PhysicalShot,
                             video: Video, hash: String, prompt: String, modelContext: ModelContext) async {
        let vid = variant.id
        busyVariantIDs.insert(vid)
        // 同时登记到进程级注册表：本 VM 可能被销毁（sheet 关闭），但轮询 Task 还在跑，
        // 下一个 VM 靠这个注册表才知道"有人正在轮询"，不会误判为僵尸。
        ShotVariantPollRegistry.shared.begin(vid)
        progress[vid] = "生成中"
        defer {
            busyVariantIDs.remove(vid)
            ShotVariantPollRegistry.shared.end(vid)
            progress[vid] = nil
        }

        do {
            let outcome = try await variantService.generate(
                sourceVideoPath: video.localPath,
                videoHash: hash,
                shotId: shot.id,
                variantId: vid,
                startFrame: shot.startFrame,
                endFrame: shot.endFrame,
                fps: video.fps,
                prompt: prompt,
                // 提交成功即落库 taskId（此后超时/崩溃/退出都不丢，可凭它查回结果）
                //
                // ⚠️ 这里**不能**用 `[weak self]` + 延迟 Task：用户关掉工作区后 VM 就释放了，
                // self 变 nil → taskId 永远写不进库 → 钱已经花了却查不回结果，
                // 而且对账时会因为查不到 taskId 而告诉用户"未扣费"（假话）。
                // 改为直接强引用 modelContext + 变体对象落库，不经过 VM。
                onTaskCreated: { tid in
                    Task { @MainActor in
                        Self.persistTaskID(tid, to: variant, modelContext: modelContext)
                    }
                },
                onStatus: { [weak self] s in Task { @MainActor in self?.progress[vid] = s } }
            )
            apply(outcome, to: variant, modelContext: modelContext)
        } catch {
            // ⚠️ 不能一律当成"提交阶段失败、未扣费"：拿到 taskId **之后**的轮询网络错误 /
            // 结果下载失败同样会抛到这里。若此时判成 .failed，UI 会给出「重新生成」→
            // 重新提交 = **第二次扣费**，而第一次已付费的结果被丢弃。
            // 判据只看有没有 taskId：有就是"已提交、已可能计费"，走免费的重试取回路径。
            if let tid = variant.taskId, !tid.isEmpty {
                variant.status = .timedOut
                variant.friendlyError = "等待结果时中断（\(FriendlyError.reason(for: error))）。任务已提交到云端，点「重试」取回结果，不会重复扣费。"
            } else {
                variant.status = .failed
                variant.friendlyError = "提交失败：\(FriendlyError.reason(for: error))"
            }
            try? modelContext.save()
            errorMessage = variant.friendlyError
        }
    }

    /// 落库 taskId（提交成功即调用）。
    ///
    /// 设计成 `static` 且直接收变体对象：调用方是 service 的回调，可能在 VM 已释放后才执行，
    /// 走实例方法会因 `self == nil` 而**静默丢掉 taskId**（等于丢掉已付费任务的唯一凭据）。
    private static func persistTaskID(_ taskId: String, to variant: ShotVariant, modelContext: ModelContext) {
        guard variant.modelContext != nil else { return }   // 变体已被删除则跳过，避免写已删对象崩溃
        variant.taskId = taskId
        modelContext.safeSave()
    }

    /// 把轮询终局落到变体状态 + 文案。
    ///
    /// ⚠️ 必须先判变体是否已被删除。轮询要等 2~4 分钟，这期间用户完全可能合并/拆分镜头
    /// （cascade 删掉 ShotVariant）。往已删对象写属性会触发 SwiftData 断言、直接崩溃。
    /// 同 `persistTaskID` 的守卫，之前只防住了那一处，这里漏了。
    private func apply(_ outcome: ShotVariantService.Outcome, to variant: ShotVariant, modelContext: ModelContext) {
        guard variant.modelContext != nil else {
            // 变体已不在了：云端若已出片，落盘文件没人引用得到，顺手清掉免得堆垃圾
            if case .completed(let r) = outcome {
                try? FileManager.default.removeItem(atPath: r.resultVideoPath)
                try? FileManager.default.removeItem(atPath: r.thumbnailPath)
                MixLog.info("[ShotEdit] 变体已被删除，丢弃云端返回结果并清理落盘文件")
            }
            return
        }
        switch outcome {
        case .completed(let r):
            variant.resultVideoPath = r.resultVideoPath
            variant.thumbnailPath = r.thumbnailPath
            variant.status = .completed
            variant.friendlyError = nil
        case .timedOut:
            variant.status = .timedOut
            variant.friendlyError = "本地等待已超过 20 分钟，任务可能仍在云端生成。点「重试」重新获取结果，不会重复扣费。"
        case .failed(let reason):
            variant.status = .failed
            variant.friendlyError = "生成失败：\(reason)"
        case .expired:
            variant.status = .failed
            variant.friendlyError = "云端结果已过期（阿里仅保留 24 小时），需重新生成（会重新计费）。"
        }
        // 这是**已付费任务的终局状态**，保存失败必须让用户知道，不能 try? 吞掉
        modelContext.saveOrWarn("画面替换结果")
    }

    /// 校验并取出可用的 video + hash；缺信息/不可编辑时置 errorMessage 并返回 nil。
    private func validatedVideo(shot: PhysicalShot, segment: Segment) -> (Video, String)? {
        guard let video = segment.video, video.fps > 0, let hash = video.contentHash else {
            errorMessage = "缺少视频信息，无法生成"; return nil
        }
        guard isEditable(shot, fps: video.fps) else {
            errorMessage = ineligibleReason(shot, fps: video.fps) ?? "该分镜头不可编辑"; return nil
        }
        return (video, hash)
    }

    /// 删除一个变体（连带落盘文件）
    func deleteVariant(_ variant: ShotVariant, modelContext: ModelContext) {
        if let p = variant.resultVideoPath { try? FileManager.default.removeItem(atPath: p) }
        if let t = variant.thumbnailPath { try? FileManager.default.removeItem(atPath: t) }
        // 若正被某坑选中，回退为原版
        for (slot, choice) in selections {
            if case .variant(let id) = choice, id == variant.id { selections[slot] = .original }
        }
        modelContext.delete(variant)
        try? modelContext.save()
    }

    // MARK: - 占位选择

    func select(orderIndex: Int, choice: SlotChoice, modelContext: ModelContext) {
        selections[orderIndex] = choice
        // 持久化到 PhysicalShot.selectedVariantID，重开工作区仍保持
        if let shot = shots.first(where: { $0.orderIndex == orderIndex }) {
            switch choice {
            case .original: shot.selectedVariantID = nil
            case .variant(let id): shot.selectedVariantID = id
            }
            try? modelContext.save()
        }
    }

    var canCompose: Bool {
        ShotEditRules.canCompose(slotCount: shots.count, selections: selections)
    }

    // MARK: - 合成新分镜

    /// 合成 → 就地给原分镜挂一版可切换的替换画面（不新增分镜）。成功返回 true。
    @discardableResult
    func compose(segment: Segment, modelContext: ModelContext) async -> Bool {
        errorMessage = nil
        guard canCompose else { errorMessage = "每个分镜头位置都要选一个版本"; return false }
        guard let video = segment.video, video.fps > 0, let hash = video.contentHash else {
            errorMessage = "缺少视频信息"; return false
        }
        isComposing = true
        defer { isComposing = false }

        // 组装占位输入（按 orderIndex 升序）
        let ordered = shots.sorted { $0.orderIndex < $1.orderIndex }
        var slots: [ShotCompositionService.SlotInput] = []
        for s in ordered {
            var variantPath: String? = nil
            if case .variant(let id) = selections[s.orderIndex] ?? .original,
               let v = s.variants.first(where: { $0.id == id }),
               v.status == .completed, let p = v.resultVideoPath {
                variantPath = p
            }
            slots.append(.init(startFrame: s.startFrame, endFrame: s.endFrame, variantVideoPath: variantPath))
        }

        do {
            let result = try await compositionService.compose(
                sourceVideoPath: video.localPath,
                fps: video.fps,
                slots: slots,
                segmentStart: segment.startTime,
                segmentEnd: segment.endTime
            )
            // 移动合成片到替换画面目录 + 生成缩略图
            let destURL = FileHelper.replacedPictureURL(videoHash: hash, segmentId: segment.id)
            try? FileManager.default.removeItem(at: destURL)
            try FileManager.default.moveItem(at: URL(fileURLWithPath: result.compositeVideoPath), to: destURL)
            let thumbURL = FileHelper.replacedPictureThumbnailURL(videoHash: hash, segmentId: segment.id)
            try? await FFmpegRunner().generateThumbnail(from: destURL.path, at: 0.0, to: thumbURL.path)
            // 就地写回原分镜（不新增 Segment/Video）
            segment.replacedPictureVideoPath = destURL.path
            // 输出路径是确定性的（重新合成后路径不变），必须显式让存在性缓存失效
            segment.invalidateReplacedExistsCache()
            segment.replacedPictureThumbnailPath = thumbURL.path
            segment.replacedPictureFrameCount = result.totalFrames   // = 探测到的实际帧数
            segment.pictureShowsReplaced = true
            // 合成产物已移到最终目录：保存失败会导致"文件在、替换画面却丢了"，必须告知
            modelContext.saveOrWarn("替换画面")
            return true
        } catch {
            errorMessage = "合成失败：\(error.localizedDescription)"
            return false
        }
    }
}


// MARK: - 轮询注册表

/// 进程级「正在轮询中的变体」注册表。
///
/// 为什么需要它：分镜头替换工作区是 sheet，每次弹出都会新建一个 `ShotEditViewModel`
/// （`@State private var vm = ShotEditViewModel()`）。而生成/重试是用裸 `Task { }` 发起的，
/// sheet 关闭后 Task 并不会自动取消，仍在后台轮询并写库。
/// 因此"是否有人在轮询"这件事**不能只存在某个 VM 实例的内存里**，否则重开工作区时
/// `reconcileStaleGenerating` 会把仍在正常轮询的变体误判为超时。
@MainActor
final class ShotVariantPollRegistry {
    static let shared = ShotVariantPollRegistry()
    private var polling: Set<UUID> = []
    private init() {}

    func begin(_ id: UUID) { polling.insert(id) }
    func end(_ id: UUID) { polling.remove(id) }
    func isPolling(_ id: UUID) -> Bool { polling.contains(id) }
}
