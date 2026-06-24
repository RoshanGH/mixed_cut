import Foundation
import SwiftData
import AVFoundation

@MainActor
@Observable
final class DubbingViewModel {
    /// 台词变体数量：默认值与可选范围（全局设置，存 UserDefaults["dubVariantCount"]）。
    static let defaultVariantCount = 2
    static let variantCountRange = 1...5

    /// 当前要产出的台词变体数量（读全局设置，越界自动夹紧到 1...5）。
    var variantCount: Int {
        let stored = UserDefaults.standard.integer(forKey: "dubVariantCount")
        let n = stored == 0 ? Self.defaultVariantCount : stored
        return min(max(n, Self.variantCountRange.lowerBound), Self.variantCountRange.upperBound)
    }

    /// 差异化改写风格池（支持最多 5 套变体；不足时按取模复用）。
    private static let rewriteStyles = [
        "口语化、活泼带感叹词，适合年轻受众的信息流广告",
        "干练直接、强调卖点与行动号召，适合效果类信息流广告",
        "场景化讲述、先痛点后给解决方案，代入感强的信息流广告",
        "突出信任与专业、强调品质与口碑背书的信息流广告",
        "限时促销、紧迫感强、强促单转化的信息流广告"
    ]
    private static let auditionText = "这款产品真的很好用，喜欢的话点击下方链接了解一下吧。"

    let topVoices: [TTSVoice] = VoiceCatalog.top(10)

    var isRewriting = false
    var rewriteProgress = ""
    var busyDubIDs: Set<UUID> = []
    var auditioningVoiceId: String?
    var playingDubID: UUID?
    var isCloning = false
    var cloneProgress = ""
    var errorMessage: String?

    private let rewriteService = ScriptRewriteService()
    private let tts: TTSClient = CosyVoiceTTSClient()
    private let vcClient: TTSClient = QwenTTSClient(model: VoiceCloneService.targetModel)
    private let vocalSep = VocalSeparationService()
    private let cloneService = VoiceCloneService()
    private let finalizer = DubAudioFinalizer()
    private var auditionPlayer: AVAudioPlayer?
    private var playbackResetTask: Task<Void, Never>?

    /// 该 voiceId 是否是这个视频的克隆原声。
    private func isCloned(_ voiceId: String, _ video: Video) -> Bool {
        guard let cv = video.clonedVoiceId else { return false }
        return voiceId == cv
    }

    // MARK: - 原声克隆（一键改写时自动确保已克隆）

    /// 确保该视频已克隆出原声音色（无则分离人声并注册）。返回是否就绪。
    /// 已去掉手动选音色：克隆原声就是唯一音色，落在 selectedVoiceIds=[clonedVoiceId]。
    @discardableResult
    func ensureClonedVoice(for video: Video, context: ModelContext) async -> Bool {
        if let cv = video.clonedVoiceId, !cv.isEmpty {
            if video.selectedVoiceIds != [cv] { video.selectedVoiceIds = [cv]; try? context.save() }
            return true
        }
        let path = video.localPath
        guard !path.isEmpty, FileManager.default.fileExists(atPath: path) else {
            errorMessage = "找不到原视频文件，无法克隆原声"
            return false
        }
        isCloning = true
        defer { isCloning = false }
        MixLog.info("[Clone] 开始克隆原声: video=\(path)")
        do {
            let hash = video.contentHash ?? video.id.uuidString
            cloneProgress = "分离人声…"
            let stems = try await vocalSep.separate(videoPath: path, videoHash: hash) { [weak self] msg in
                Task { @MainActor in self?.cloneProgress = msg }
            }
            MixLog.info("[Clone] 分离完成: vocals=\(stems.vocalsPath)")
            cloneProgress = "提取克隆参考…"
            // 参考音必须【短而干净】(≈6s)：18s 长参考含多句原话，qwen 克隆 TTS 会间歇性
            // "续读参考里的内容"导致配音混进下一段(实测 18s→clean 1/3，6s→clean 5/5)。
            let ref = try await vocalSep.referenceClip(fromVocals: stems.vocalsPath, maxSeconds: 6)
            cloneProgress = "注册克隆音色…"
            let voiceId = try await cloneService.enroll(referenceAudioPath: ref,
                                                        preferredName: "mixcut\(hash.prefix(8))")
            MixLog.info("[Clone] 克隆成功: voiceId=\(voiceId)")
            video.clonedVoiceId = voiceId
            video.selectedVoiceIds = [voiceId]
            try? context.save()
            cloneProgress = ""
            return true
        } catch {
            cloneProgress = ""
            MixLog.error("[Clone] 克隆失败: \(error.localizedDescription)")
            errorMessage = "原声克隆失败：\(error.localizedDescription)"
            return false
        }
    }

    // MARK: - 一键改写（自动克隆原声 → 改写 K 套台词 → 克隆配音）

    func rewriteAll(video: Video, context: ModelContext) async {
        guard await ensureClonedVoice(for: video, context: context) else { return }
        let voices = video.selectedVoiceIds   // = [clonedVoiceId]
        guard !voices.isEmpty else { errorMessage = "克隆原声未就绪"; return }
        let reconfigurable = video.segments.filter { !$0.isVoiceLocked && !$0.text.isEmpty }
        guard !reconfigurable.isEmpty else { errorMessage = "没有可重配的分镜"; return }

        isRewriting = true
        defer { isRewriting = false }

        let inputs = reconfigurable.map {
            RewriteSegmentInput(segmentId: $0.id.uuidString,
                                originalText: $0.text,
                                durationSeconds: $0.duration,
                                keywords: $0.keywords)
        }
        let segById = Dictionary(uniqueKeysWithValues: reconfigurable.map { ($0.id.uuidString, $0) })

        let n = variantCount
        for k in 0..<n {
            rewriteProgress = "改写第 \(k + 1)/\(n) 套…"
            do {
                let results = try await rewriteService.rewrite(
                    inputs: inputs,
                    style: Self.rewriteStyles[k % Self.rewriteStyles.count])
                for r in results {
                    guard let seg = segById[r.segmentId] else { continue }
                    for voiceId in voices {
                        upsertDub(segment: seg, voiceId: voiceId, textVariantIndex: k,
                                  text: r.rewrittenText, context: context)
                    }
                }
                try? context.save()
            } catch {
                errorMessage = "改写失败：\(error.localizedDescription)"
                return
            }
        }
        rewriteProgress = ""

        // 改写完成后自动批量合成 TTS（用户无需逐格手动点）
        let result = await generateAllAudio(for: reconfigurable, context: context)

        let producedCount = reconfigurable.count * voices.count * n
        if result.fail > 0 {
            ToastCenter.shared.show(
                "已生成 \(producedCount) 个变体，配音合成 \(result.ok) 成功 / \(result.fail) 失败，失败项可在分镜右侧点 ↻ 重试",
                icon: "exclamationmark.triangle.fill",
                style: .warning,
                duration: 4.0)
        } else {
            ToastCenter.shared.show(
                "已生成 \(producedCount) 个配音变体并完成 TTS 合成，点开任意分镜可在右侧试听",
                icon: "checkmark.circle.fill",
                style: .success,
                duration: 3.5)
        }
    }

    // MARK: - 单分镜重新改写（改完原台词后只重出本分镜的 K 套改写 + TTS）

    func rewriteSegment(_ segment: Segment, context: ModelContext) async {
        guard let video = segment.video else { return }
        guard !segment.isVoiceLocked else { errorMessage = "该分镜保留原声，不参与配音"; return }
        guard !segment.text.isEmpty else { errorMessage = "该分镜没有原台词"; return }
        guard await ensureClonedVoice(for: video, context: context) else { return }
        let voices = video.selectedVoiceIds   // = [clonedVoiceId]
        guard !voices.isEmpty else { errorMessage = "克隆原声未就绪"; return }

        isRewriting = true
        defer { isRewriting = false }

        let input = RewriteSegmentInput(segmentId: segment.id.uuidString,
                                        originalText: segment.text,
                                        durationSeconds: segment.duration,
                                        keywords: segment.keywords)
        let n = variantCount
        for k in 0..<n {
            rewriteProgress = "改写第 \(k + 1)/\(n) 套…"
            do {
                let results = try await rewriteService.rewrite(
                    inputs: [input],
                    style: Self.rewriteStyles[k % Self.rewriteStyles.count])
                if let r = results.first {
                    for voiceId in voices {
                        upsertDub(segment: segment, voiceId: voiceId, textVariantIndex: k,
                                  text: r.rewrittenText, context: context)
                    }
                }
                try? context.save()
            } catch {
                errorMessage = "改写失败：\(error.localizedDescription)"
                return
            }
        }
        rewriteProgress = ""

        let result = await generateAllAudio(for: [segment], context: context)
        if result.fail > 0 {
            ToastCenter.shared.show("本分镜已重写，配音 \(result.ok) 成功 / \(result.fail) 失败",
                                    icon: "exclamationmark.triangle.fill", style: .warning, duration: 3.5)
        } else {
            ToastCenter.shared.show("本分镜已重新改写并生成配音",
                                    icon: "checkmark.circle.fill", style: .success)
        }
    }

    // MARK: - 编辑某改写版台词（改完重生成该版 TTS）

    /// 把某 textVariant 下所有音色的台词改成 newText，清旧音频并重生成 TTS。
    func updateVariantText(segment: Segment, textVariantIndex t: Int,
                           newText: String, context: ModelContext) async {
        let trimmed = newText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { errorMessage = "台词不能为空"; return }

        let dubs = segment.segmentDubs.filter { $0.textVariantIndex == t }
        guard !dubs.isEmpty else { return }
        var changed = false
        for d in dubs where d.rewrittenText != trimmed {
            d.rewrittenText = trimmed
            d.audioFilePath = nil
            d.status = .pending
            changed = true
        }
        guard changed else { return }
        try? context.save()

        isRewriting = true
        defer { isRewriting = false }
        rewriteProgress = "重新合成本版配音…"
        let result = await generateAllAudio(for: [segment], context: context)
        rewriteProgress = ""
        if result.fail > 0 {
            ToastCenter.shared.show("台词已更新，配音 \(result.ok) 成功 / \(result.fail) 失败",
                                    icon: "exclamationmark.triangle.fill", style: .warning, duration: 3.5)
        } else {
            ToastCenter.shared.show("台词已更新并重新生成配音", icon: "checkmark.circle.fill", style: .success)
        }
    }

    /// qwen 克隆 TTS 偶发"续读参考内容"(合成音频比台词长、混进下一段，且常带重复)。
    /// 干净版必然最短：重试最多 3 次取最短结果；某次时长 ≤ 字数×阈值(视为干净)即提前返回。
    private static func synthesizeCloneRobust(client: TTSClient, text: String, voiceId: String) async throws -> TTSResult {
        let maxTries = 3
        let cleanLimit = Double(max(1, text.count)) * 0.28   // 秒/字上限，超过疑似跑飞
        var best: TTSResult?
        for _ in 0..<maxTries {
            let r = try await client.synthesize(text: text, voiceId: voiceId, languageType: "Chinese", rate: 1.0)
            if best == nil || r.rawDuration < best!.rawDuration { best = r }
            if r.rawDuration <= cleanLimit { break }   // 看着干净，直接用
        }
        return best!
    }

    /// 同 (分镜, 音色, 改写版) 已存在则更新文本（文本变更则清空旧音频），否则新建。
    private func upsertDub(segment: Segment, voiceId: String, textVariantIndex: Int,
                           text: String, context: ModelContext) {
        if let existing = segment.segmentDubs.first(where: {
            $0.voiceId == voiceId && $0.textVariantIndex == textVariantIndex
        }) {
            if existing.rewrittenText != text {
                existing.rewrittenText = text
                existing.audioFilePath = nil
                existing.status = .pending
            }
        } else {
            let dub = SegmentDub(segment: segment, voiceId: voiceId,
                                 textVariantIndex: textVariantIndex, rewrittenText: text)
            context.insert(dub)
            segment.segmentDubs.append(dub)
        }
    }

    // MARK: - 按需生成单格音频

    /// - Parameter silent: 批量生成时传 true，失败不逐条弹窗（由调用方汇总）。
    /// - Returns: 是否生成成功。
    @discardableResult
    func generateAudio(for dub: SegmentDub, context: ModelContext, silent: Bool = false) async -> Bool {
        guard let segment = dub.segment, let video = segment.video else { return false }
        guard !dub.rewrittenText.isEmpty else {
            if !silent { errorMessage = "该变体没有台词" }
            return false
        }
        let cloned = isCloned(dub.voiceId, video)
        // 防御：非克隆音色必须在当前 CosyVoice 目录里，否则引擎会报 418
        guard cloned || VoiceCatalog.voice(id: dub.voiceId) != nil else {
            if !silent { errorMessage = "该变体的音色已失效（旧音色），请在顶部重选音色后重新「一键改写」" }
            return false
        }
        busyDubIDs.insert(dub.id)
        defer { busyDubIDs.remove(dub.id) }
        do {
            let target = segment.duration
            let bias = video.dubSpeechRate
            // 克隆音色走 qwen-vc（无数值语速，靠 atempo 对齐）；其它走 CosyVoice + rate 对齐
            let client = cloned ? vcClient : tts
            var result: TTSResult
            if cloned {
                // qwen 克隆 TTS 间歇性"续读参考内容/跑飞"(音频比台词长，混进下一段)：
                // 干净版必然最短 → 重试取最短，看着干净(时长≤字数×阈值)即提前采用。
                result = try await Self.synthesizeCloneRobust(
                    client: client, text: dub.rewrittenText, voiceId: dub.voiceId)
            } else {
                result = try await client.synthesize(text: dub.rewrittenText, voiceId: dub.voiceId,
                                                     languageType: "Chinese", rate: 1.0)
                if let retarget = SpeechRatePlanner.retargetRate(
                    targetDuration: target, measuredDuration: result.rawDuration,
                    measuredAtRate: 1.0, bias: bias) {
                    result = try await client.synthesize(text: dub.rewrittenText, voiceId: dub.voiceId,
                                                         languageType: "Chinese", rate: retarget)
                }
            }
            let finalized = try await finalizer.finalize(
                tts: result, targetDuration: target, fps: video.fps > 0 ? video.fps : 30,
                videoHash: video.contentHash ?? video.id.uuidString,
                segmentId: segment.id, voiceId: dub.voiceId, textVariantIndex: dub.textVariantIndex)
            dub.audioFilePath = finalized.m4aPath
            dub.atempoFactor = finalized.plan.atempoFactor
            dub.freezePadFrames = finalized.plan.freezePadFrames
            dub.trailingSilence = finalized.plan.trailingSilence
            // 对齐后实际音频时长（atempo 变速后），用于在变体池展示
            dub.audioDuration = result.rawDuration / max(0.0001, finalized.plan.atempoFactor)
            dub.generatedForStartFrame = segment.startFrame
            dub.generatedForEndFrame = segment.endFrame
            dub.generatedForTextHash = DubStaleness.textHash(of: dub.rewrittenText)
            dub.status = .generated
            try? context.save()
            return true
        } catch {
            dub.status = .failed
            try? context.save()
            if !silent { errorMessage = "配音生成失败：\(error.localizedDescription)" }
            return false
        }
    }

    /// 批量合成一组分镜下所有「还没音频」的变体（一键改写后自动调用）。
    private func generateAllAudio(for segments: [Segment], context: ModelContext) async -> (ok: Int, fail: Int) {
        let pending = segments
            .flatMap { $0.segmentDubs }
            .filter { $0.audioFilePath == nil && !$0.rewrittenText.isEmpty }
        guard !pending.isEmpty else { return (0, 0) }
        var ok = 0, fail = 0
        for dub in pending {
            rewriteProgress = "合成配音 \(ok + fail + 1)/\(pending.count)…"
            if await generateAudio(for: dub, context: context, silent: true) { ok += 1 } else { fail += 1 }
        }
        rewriteProgress = ""
        return (ok, fail)
    }

    // MARK: - 试听已生成的变体音频（对齐后的成片音频）

    /// 播放某个变体已生成的音频文件（再次点击同一变体则停止）。
    func playDub(_ dub: SegmentDub) {
        if playingDubID == dub.id { stopDubPlayback(); return }
        guard let path = dub.audioFilePath, FileManager.default.fileExists(atPath: path) else {
            errorMessage = "音频文件不存在，请重新生成该变体"
            return
        }
        do {
            let player = try AVAudioPlayer(contentsOf: URL(fileURLWithPath: path))
            auditionPlayer = player
            player.play()
            playingDubID = dub.id
            // 播完自动复位高亮（AVAudioPlayer 的 delegate 需要 NSObject，这里用时长定时复位更简单）
            playbackResetTask?.cancel()
            let duration = max(0.1, player.duration)
            playbackResetTask = Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(duration * 1_000_000_000))
                guard !Task.isCancelled else { return }
                if self?.playingDubID == dub.id { self?.playingDubID = nil }
            }
        } catch {
            errorMessage = "播放失败：\(error.localizedDescription)"
        }
    }

    func stopDubPlayback() {
        playbackResetTask?.cancel()
        playbackResetTask = nil
        auditionPlayer?.stop()
        auditionPlayer = nil
        playingDubID = nil
    }

    // MARK: - 导出前补齐选定变体音频

    /// 对方案里被选中但还没音频的变体按需补齐合成（导出前调用）。
    func ensureSelectedAudio(for scheme: MixScheme, context: ModelContext) async {
        for ss in scheme.orderedSegments {
            guard let id = ss.selectedSegmentDubId,
                  let dub = ss.segment?.segmentDubs.first(where: { $0.id == id }),
                  dub.audioFilePath == nil else { continue }
            await generateAudio(for: dub, context: context)
        }
    }

    // MARK: - 试听音色样例

    func audition(voiceId: String, rate: Double = 1.0, cloned: Bool = false) async {
        auditioningVoiceId = voiceId
        defer { auditioningVoiceId = nil }
        do {
            let client = cloned ? vcClient : tts
            let result = try await client.synthesize(text: Self.auditionText, voiceId: voiceId,
                                                     languageType: "Chinese", rate: rate)
            let player = try AVAudioPlayer(contentsOf: URL(fileURLWithPath: result.wavPath))
            auditionPlayer = player
            player.play()
        } catch {
            errorMessage = "试听失败：\(error.localizedDescription)"
        }
    }
}
