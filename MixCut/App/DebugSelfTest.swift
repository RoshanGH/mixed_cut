#if DEBUG
import Foundation
import SwiftData

/// DEBUG-only 自检入口（环境变量 MIXCUT_SELFTEST=1 触发）。
/// 在真实库上跑通 G2 分镜库变体导出全链路 + G3 组合数学，产出真实文件并写报告。
/// 对正常使用零影响：仅 DEBUG 编译、仅在显式设置环境变量时运行。
enum DebugSelfTest {

    @MainActor
    static func runIfRequested(container: ModelContainer) {
        let env = ProcessInfo.processInfo.environment
        if let s = env["MIXCUT_SELFTEST_SHORTREF"], let secs = Double(s) { runShortRef(container: container, refSecs: secs); return }
        if env["MIXCUT_SELFTEST_REGENDUB"] == "1" { runRegenDub(container: container); return }
        if env["MIXCUT_SELFTEST_TTSX"] == "1" { runTTSx(container: container); return }
        if let f = env["MIXCUT_ASRFILE"], !f.isEmpty { runASRFile(path: f); return }
        if env["MIXCUT_SELFTEST_REID"] == "1" { runReid(container: container); return }
        if env["MIXCUT_SELFTEST_DRIFT"] == "1" { runDrift(container: container); return }
        if env["MIXCUT_SELFTEST_ASRFULL"] == "1" { runASRFull(container: container); return }
        if env["MIXCUT_SELFTEST_ASR"] == "1" { runASR(container: container); return }
        if env["MIXCUT_SELFTEST_CLEAN"] == "1" { runCleanFanout(container: container); return }
        if let n = env["MIXCUT_SELFTEST_GEN_REAL"], let t = Int(n) { runGenReal(container: container, target: t); return }
        if env["MIXCUT_SELFTEST_REWRITE"] == "1" { runRewrite(container: container); return }
        if let n = env["MIXCUT_SELFTEST_GEN"], let target = Int(n) { runGenSchemes(container: container, target: target); return }
        guard env["MIXCUT_SELFTEST"] == "1" else { return }
        let outPath = ProcessInfo.processInfo.environment["MIXCUT_SELFTEST_OUT"]
            ?? NSTemporaryDirectory() + "mixcut_selftest.txt"

        let ctx = container.mainContext
        var lines: [String] = ["# MixCut 自检报告"]

        guard let videos = try? ctx.fetch(FetchDescriptor<Video>()), !videos.isEmpty else {
            write(outPath, ["无视频，跳过"]); return
        }
        // 选变体最多的视频
        let video = videos.max {
            $0.segments.flatMap(\.segmentDubs).count < $1.segments.flatMap(\.segmentDubs).count
        }!
        let segs = video.segments.sorted { $0.segmentIndex < $1.segmentIndex }
        var seq: [UUID: Int] = [:]
        for (i, s) in segs.enumerated() { seq[s.id] = i + 1 }

        lines.append("视频: \(video.name)")
        lines.append("分镜数: \(segs.count)，含音频变体总数: \(segs.flatMap(\.segmentDubs).filter { $0.audioFilePath != nil }.count)")

        // —— G3 组合数学（真实数据，纯逻辑，不落库）——
        lines.append("\n## G3 笛卡尔积组合(每模板≤8)")
        let slots: [SlotOptions] = segs.map { s in
            SlotOptions(isLocked: s.isVoiceLocked,
                        includeOriginal: s.isVoiceLocked ? true : s.originalParticipatesInCombination,
                        dubIds: s.isVoiceLocked ? [] : s.combinationDubVariants.map(\.id))
        }
        let combo = VariantCombinationGenerator.generate(slots: slots, limit: 256)
        lines.append("可行组合总数(feasible)=\(combo.feasibleCount)，实取=\(combo.combinations.count)，截断=\(combo.truncated)")

        // —— G2 变体导出（真实 App 层链路）——
        let jobs = VariantExportInput.from(segments: segs) { seq[$0.id] ?? 0 }
        let originals = jobs.filter { if case .original = $0 { return true } else { return false } }.count
        let variants = jobs.count - originals
        lines.append("\n## G2 导出任务展开")
        lines.append("任务总数=\(jobs.count)（原版=\(originals)，变体=\(variants)）")
        lines.append("文件名样例: " + jobs.prefix(8).map(\.fileName).joined(separator: ", "))

        let outDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("mixcut_selftest_export", isDirectory: true)
        try? FileManager.default.removeItem(at: outDir)
        try? FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

        let svc = VariantBatchExportService()
        let jobsCopy = jobs
        Task.detached {
            let result = await svc.exportAll(jobs: jobsCopy, outputDirectory: outDir,
                                             config: ExportConfig()) { _ in }
            var report = lines
            report.append("\n## G2 实导出结果")
            report.append("成功=\(result.succeeded)，失败=\(result.failed.count)")
            for f in result.failed { report.append("  失败: \(f.0) — \(f.1)") }
            // 列出产物文件 + 大小
            if let files = try? FileManager.default.contentsOfDirectory(atPath: outDir.path) {
                report.append("产物文件(\(files.count)):")
                for f in files.sorted() {
                    let attrs = try? FileManager.default.attributesOfItem(atPath: outDir.appendingPathComponent(f).path)
                    let sz = (attrs?[.size] as? Int) ?? 0
                    report.append("  \(f)  \(sz) bytes")
                }
                // 探测一个变体文件是否含音频流（用 bundle 内 ffmpeg -i）
                if let oneVariant = files.first(where: { $0.contains("_") && $0.hasSuffix(".mp4") }) {
                    let probe = Self.ffmpegProbe(outDir.appendingPathComponent(oneVariant).path)
                    report.append("变体探测 \(oneVariant):\n\(probe)")
                }
            }
            report.append("\n[done] 导出目录: \(outDir.path)")
            Self.write(outPath, report)
        }
        // 先写一份(同步部分),异步结果稍后覆盖
        write(outPath, lines + ["\n[导出进行中…完成后本文件会被覆盖]"])
    }

    // MARK: - 在「含已克隆视频的真实项目」上生成方案（新代码：每方案一条原序列 + 组合数提示），不删

    @MainActor
    static func runGenReal(container: ModelContainer, target: Int) {
        let outPath = ProcessInfo.processInfo.environment["MIXCUT_SELFTEST_OUT"]
            ?? NSTemporaryDirectory() + "mixcut_genreal.txt"
        let ctx = container.mainContext
        guard let videos = try? ctx.fetch(FetchDescriptor<Video>()),
              let video = videos.first(where: { ($0.clonedVoiceId ?? "").isEmpty == false }),
              let project = video.projectVideos.compactMap({ $0.project }).first else {
            write(outPath, ["未找到含克隆视频的项目"]); return
        }
        write(outPath, ["# 在真实项目生成方案", "项目: \(project.name)", "[运行中…]"])
        let vm = SchemeViewModel()
        vm.setModelContext(ctx)
        Task { @MainActor in
            await vm.generateSchemes(for: project, targetVideoCount: target)
            let ai = vm.aiStrategies
            var r = ["# 在真实项目生成方案(完成)", "项目: \(project.name)",
                     "进度: \(vm.generationProgress)",
                     "AI策略数: \(ai.count)"]
            for st in ai {
                r.append("  策略「\(st.name)」: \(st.orderedSchemes.count) 个方案")
                if let sc = st.orderedSchemes.first {
                    let factors = sc.orderedSegments.map { ss -> Int in
                        guard let seg = ss.segment else { return 1 }
                        return seg.combinationSlotCount
                    }
                    r.append("    样例方案「\(sc.name)」组合数=\(factors.reduce(1,*)) (\(factors.map(String.init).joined(separator: "×")))")
                }
            }
            if let err = vm.errorMessage { r.append("errorMessage: \(err)") }
            r.append("[done]")
            write(outPath, r)
        }
    }

    // MARK: - 清理测试期 fan-out 残留（templateGroupId != nil 的方案 + 清空的AI策略）

    @MainActor
    static func runCleanFanout(container: ModelContainer) {
        let outPath = ProcessInfo.processInfo.environment["MIXCUT_SELFTEST_OUT"]
            ?? NSTemporaryDirectory() + "mixcut_clean.txt"
        let ctx = container.mainContext
        var removedSchemes = 0
        if let schemes = try? ctx.fetch(FetchDescriptor<MixScheme>()) {
            for sc in schemes where sc.templateGroupId != nil {
                ctx.delete(sc); removedSchemes += 1
            }
        }
        try? ctx.save()
        // 删掉因此清空、且非自定义/非叙事的 AI 策略
        var removedStrats = 0
        if let strats = try? ctx.fetch(FetchDescriptor<MixStrategy>()) {
            for st in strats where st.schemes.isEmpty && !st.isCustomGroup && !st.isNarrativeTemplate {
                ctx.delete(st); removedStrats += 1
            }
        }
        try? ctx.save()
        write(outPath, ["# 清理 fan-out 残留", "删除方案: \(removedSchemes)", "删除空AI策略: \(removedStrats)", "[done]"])
    }

    // MARK: - 测短参考音的 clean 率（用 N 秒参考重新克隆，同台词合成5次看漏读几次）

    @MainActor
    static func runShortRef(container: ModelContainer, refSecs: Double) {
        let outPath = ProcessInfo.processInfo.environment["MIXCUT_SELFTEST_OUT"]
            ?? NSTemporaryDirectory() + "mixcut_shortref.txt"
        let ctx = container.mainContext
        guard let videos = try? ctx.fetch(FetchDescriptor<Video>()),
              let video = videos.first(where: { $0.name.contains("XCT") }),
              let hash = video.contentHash else { write(outPath, ["无 XCT 视频"]); return }
        let vocals = FileHelper.stemsDirectory(videoHash: hash).appendingPathComponent("vocals.wav").path
        guard FileManager.default.fileExists(atPath: vocals) else { write(outPath, ["无 vocals.wav 缓存"]); return }
        let text = "你真能忍冰箱发霉还带着异味？还不快试试这款滴露除菌喷雾吗？"
        write(outPath, ["# 短参考 clean 率测试 ref=\(refSecs)s", "台词29字: \(text)", "[运行中…]"])
        let sep = VocalSeparationService()
        let clone = VoiceCloneService()
        let vc = QwenTTSClient(model: VoiceCloneService.targetModel)
        let asr = QwenASRClient()
        let ff = FFmpegRunner()
        Task.detached {
            var r = ["# 短参考 clean 率测试 ref=\(refSecs)s", "台词29字(\(text.count)字)"]
            do {
                let ref = try await sep.referenceClip(fromVocals: vocals, maxSeconds: refSecs)
                let vid = try await clone.enroll(referenceAudioPath: ref, preferredName: "shortref\(Int(refSecs))")
                r.append("新克隆 voice=\(vid.prefix(34))")
                var clean = 0
                for i in 1...5 {
                    let res = try await vc.synthesize(text: text, voiceId: vid, languageType: "Chinese", rate: 1.0)
                    let pcm = FileHelper.tempDirectory.appendingPathComponent("sr-\(UUID().uuidString).pcm")
                    try await ff.extractAudioPCM(from: res.wavPath, to: pcm.path)
                    let got = try await asr.transcribe(pcmPath: pcm.path)
                    try? FileManager.default.removeItem(at: pcm)
                    let isClean = got.count <= text.count + 6
                    if isClean { clean += 1 }
                    r.append("第\(i)次 \(String(format: "%.1f", res.rawDuration))s \(got.count)字 \(isClean ? "✅" : "❌漏"): \(got.prefix(50))")
                }
                r.append("clean 率: \(clean)/5")
            } catch { r.append("失败: \(error.localizedDescription)") }
            r.append("[done]")
            write(outPath, r)
        }
    }

    // MARK: - 走真实 generateAudio(重试取最短)重生成 seg_002 配音并验证干净

    @MainActor
    static func runRegenDub(container: ModelContainer) {
        let outPath = ProcessInfo.processInfo.environment["MIXCUT_SELFTEST_OUT"]
            ?? NSTemporaryDirectory() + "mixcut_regendub.txt"
        let ctx = container.mainContext
        guard let videos = try? ctx.fetch(FetchDescriptor<Video>()),
              let video = videos.first(where: { $0.name.contains("XCT") }),
              let seg = video.segments.first(where: { $0.segmentIndex == "seg_002" }),
              let dub = seg.segmentDubs.first(where: { $0.audioFilePath != nil }) ?? seg.segmentDubs.first else {
            write(outPath, ["无 XCT seg_002 变体"]); return
        }
        let segDur = seg.duration
        let rw = dub.rewrittenText
        write(outPath, ["# 重生成 seg_002 配音(重试取最短)", "分镜\(String(format: "%.1f", segDur))s 改写(\(rw.count)字): \(rw)", "[运行中…]"])
        let vm = DubbingViewModel()
        let asr = QwenASRClient()
        let ff = FFmpegRunner()
        Task { @MainActor in
            let okGen = await vm.generateAudio(for: dub, context: ctx)
            var r = ["# 重生成 seg_002 配音(重试取最短)", "分镜\(String(format: "%.1f", segDur))s 改写(\(rw.count)字): \(rw)",
                     "generateAudio 成功=\(okGen)  新 audioDuration=\(String(format: "%.1f", dub.audioDuration))s"]
            if let path = dub.audioFilePath {
                let pcm = FileHelper.tempDirectory.appendingPathComponent("rd-\(UUID().uuidString).pcm")
                do {
                    try await ff.extractAudioPCM(from: path, to: pcm.path)
                    let got = try await asr.transcribe(pcmPath: pcm.path)
                    r.append("产物实际内容(\(got.count)字): \(got)")
                    r.append(got.count <= rw.count + 6 ? "✅ 干净(无多余内容)" : "❌ 仍漏读")
                } catch { r.append("转写失败: \(error.localizedDescription)") }
                try? FileManager.default.removeItem(at: pcm)
            }
            r.append("[done]")
            write(outPath, r)
        }
    }

    // MARK: - 同一克隆音色把同一台词连合成多次（诊断:漏读是偶发还是必现）

    @MainActor
    static func runTTSx(container: ModelContainer) {
        let outPath = ProcessInfo.processInfo.environment["MIXCUT_SELFTEST_OUT"]
            ?? NSTemporaryDirectory() + "mixcut_ttsx.txt"
        let ctx = container.mainContext
        guard let videos = try? ctx.fetch(FetchDescriptor<Video>()),
              let video = videos.first(where: { ($0.clonedVoiceId ?? "").isEmpty == false }),
              let voiceId = video.clonedVoiceId else {
            write(outPath, ["无克隆音色视频"]); return
        }
        let text = "你真能忍冰箱发霉还带着异味？还不快试试这款滴露除菌喷雾吗？"   // seg_002 改写台词 29字
        write(outPath, ["# 同台词连合成3次(克隆音色)", "voice=\(voiceId.prefix(34))", "台词(29字): \(text)", "[运行中…]"])
        let vc = QwenTTSClient(model: VoiceCloneService.targetModel)
        let asr = QwenASRClient()
        let ff = FFmpegRunner()
        Task.detached {
            var r = ["# 同台词连合成3次(克隆音色)", "台词(29字): \(text)"]
            for i in 1...3 {
                do {
                    let res = try await vc.synthesize(text: text, voiceId: voiceId, languageType: "Chinese", rate: 1.0)
                    // 转写产物看实际念了啥
                    let pcm = FileHelper.tempDirectory.appendingPathComponent("ttsx-\(UUID().uuidString).pcm")
                    try await ff.extractAudioPCM(from: res.wavPath, to: pcm.path)
                    let got = try await asr.transcribe(pcmPath: pcm.path)
                    try? FileManager.default.removeItem(at: pcm)
                    r.append("第\(i)次: 原始时长\(String(format: "%.1f", res.rawDuration))s  内容(\(got.count)字): \(got.prefix(60))")
                } catch {
                    r.append("第\(i)次 失败: \(error.localizedDescription)")
                }
            }
            r.append("[done]")
            write(outPath, r)
        }
    }

    // MARK: - 把任意音频文件转文字（诊断:生成的配音里到底念了啥）

    static func runASRFile(path: String) {
        let outPath = ProcessInfo.processInfo.environment["MIXCUT_SELFTEST_OUT"]
            ?? NSTemporaryDirectory() + "mixcut_asrfile.txt"
        let ff = FFmpegRunner()
        let asr = QwenASRClient()
        Task.detached {
            var r = ["# ASR 文件诊断", "文件: \((path as NSString).lastPathComponent)"]
            let pcm = FileHelper.tempDirectory.appendingPathComponent("asrfile-\(UUID().uuidString).pcm")
            do {
                // m4a/wav → 16k 单声道裸 PCM（extractAudioPCM 接受任意含音轨的文件）
                try await ff.extractAudioPCM(from: path, to: pcm.path)
                let text = try await asr.transcribe(pcmPath: pcm.path)
                r.append("识别出的内容(\(text.count)字): \(text)")
            } catch {
                r.append("失败: \(error.localizedDescription)")
            }
            try? FileManager.default.removeItem(at: pcm)
            r.append("[done]")
            write(outPath, r)
        }
    }

    // MARK: - 实跑 reidentifyWholeVideo（逐分镜 clip-ASR）并报告结果

    @MainActor
    static func runReid(container: ModelContainer) {
        let outPath = ProcessInfo.processInfo.environment["MIXCUT_SELFTEST_OUT"]
            ?? NSTemporaryDirectory() + "mixcut_reid.txt"
        let ctx = container.mainContext
        guard let videos = try? ctx.fetch(FetchDescriptor<Video>()) else { write(outPath, ["无视频"]); return }
        let video = videos.first(where: { $0.name.contains("XCT") && !$0.segments.isEmpty })
            ?? videos.first(where: { !$0.segments.isEmpty })
        guard let video else { write(outPath, ["无带分镜视频"]); return }
        let name = video.name
        write(outPath, ["# 实跑 reidentifyWholeVideo(逐分镜 clip-ASR)", "视频: \(name.prefix(24))", "[运行中…]"])
        let vm = ImportViewModel()
        Task { @MainActor in
            await vm.reidentifyWholeVideo(video, context: ctx)
            var r = ["# reidentifyWholeVideo 完成", "视频: \(name.prefix(24))"]
            for (i, seg) in video.segments.sorted(by: { $0.startFrame < $1.startFrame }).enumerated().prefix(5) {
                r.append("#\(i+1) \(seg.segmentIndex): \(seg.text.prefix(40))")
            }
            r.append("[done]")
            write(outPath, r)
        }
    }

    // MARK: - DRIFT 诊断：整片时间戳切出的存量台词 vs 单段音频重切

    @MainActor
    static func runDrift(container: ModelContainer) {
        let outPath = ProcessInfo.processInfo.environment["MIXCUT_SELFTEST_OUT"]
            ?? NSTemporaryDirectory() + "mixcut_drift.txt"
        let ctx = container.mainContext
        guard let videos = try? ctx.fetch(FetchDescriptor<Video>()) else { write(outPath, ["无视频"]); return }
        // 优先 XCT；否则取第一个有分镜的
        let video = videos.first(where: { $0.name.contains("XCT") && !$0.segments.isEmpty })
            ?? videos.first(where: { !$0.segments.isEmpty })
        guard let video, !video.localPath.isEmpty, FileManager.default.fileExists(atPath: video.localPath) else {
            write(outPath, ["无可用视频"]); return
        }
        let fps = video.fps > 0 ? video.fps : 30
        let segs = video.segments.sorted { $0.startFrame < $1.startFrame }
        // 取 #2/#3/#4（索引1..3）
        let picks = Array(segs.enumerated()).filter { (1...3).contains($0.offset) }
            .map { (idx: $0.offset + 1, start: Double($0.element.startFrame) / fps,
                    end: Double($0.element.endFrame) / fps, stored: $0.element.text) }
        let path = video.localPath
        write(outPath, ["# DRIFT 诊断: 存量台词(整片时间戳) vs 单段音频重切", "视频: \(video.name.prefix(24))", "[运行中…]"])
        let ff = FFmpegRunner()
        let asr = QwenASRClient()
        Task.detached {
            var r = ["# DRIFT 诊断(完成)", "视频: \(video.name.prefix(24))"]
            // 限速后的整片识别 → 按分镜边界切片
            var fullWords: [ASRWord] = []
            do {
                let fpcm = FileHelper.tempDirectory.appendingPathComponent("driftfull-\(UUID().uuidString).pcm")
                try await ff.extractAudioPCM(from: path, to: fpcm.path)
                fullWords = try await asr.transcribeFull(pcmPath: fpcm.path).words
                try? FileManager.default.removeItem(at: fpcm)
                r.append("限速整片 words=\(fullWords.count)")
            } catch { r.append("限速整片失败: \(error.localizedDescription)") }
            func slice(_ s: Double, _ e: Double) -> String {
                fullWords.filter { $0.start >= s && $0.start < e }.map(\.word).joined()
            }
            for p in picks {
                let pcm = FileHelper.tempDirectory.appendingPathComponent("drift-\(UUID().uuidString).pcm")
                do {
                    try await ff.extractSegmentPCM(from: path, start: p.start, end: p.end, to: pcm.path)
                    let clip = try await asr.transcribe(pcmPath: pcm.path)
                    r.append("#\(p.idx) [\(String(format: "%.1f", p.start))-\(String(format: "%.1f", p.end))]s")
                    r.append("   存量(旧漂移): \(p.stored.prefix(36))")
                    r.append("   限速整片切 : \(slice(p.start, p.end).prefix(36))")
                    r.append("   单段真值   : \(clip.prefix(36))")
                } catch {
                    r.append("#\(p.idx) 失败: \(error.localizedDescription)")
                }
                try? FileManager.default.removeItem(at: pcm)
            }
            r.append("[done]")
            write(outPath, r)
        }
    }

    // MARK: - SPIKE：整片 paraformer 时间戳精度验证

    @MainActor
    static func runASRFull(container: ModelContainer) {
        let outPath = ProcessInfo.processInfo.environment["MIXCUT_SELFTEST_OUT"]
            ?? NSTemporaryDirectory() + "mixcut_asrfull.txt"
        let ctx = container.mainContext
        guard let videos = try? ctx.fetch(FetchDescriptor<Video>()) else { write(outPath, ["无视频"]); return }
        let infos: [(name: String, path: String, dur: Double)] = videos
            .filter { !$0.segments.isEmpty && !$0.localPath.isEmpty && FileManager.default.fileExists(atPath: $0.localPath) }
            .map { ($0.name, $0.localPath, $0.duration) }
        write(outPath, ["# SPIKE 整片 paraformer 句子粒度(全部视频)", "[运行中…]"])
        let ff = FFmpegRunner()
        let asr = QwenASRClient()
        Task.detached {
            var r = ["# SPIKE 整片 paraformer 句子粒度(完成)"]
            for info in infos {
                let pcm = FileHelper.tempDirectory.appendingPathComponent("spike-\(UUID().uuidString).pcm")
                do {
                    try await ff.extractAudioPCM(from: info.path, to: pcm.path)
                    let res = try await asr.transcribeFull(pcmPath: pcm.path)
                    // 含句末标点的句子数(说明是 run-on,本应再切)
                    let runOns = res.rawSentences.filter { s in
                        let inner = s.text.dropLast()  // 去掉结尾标点
                        return inner.contains("。") || inner.contains("！") || inner.contains("？")
                    }.count
                    r.append("· \(info.name.prefix(22)) 时长\(String(format: "%.0f", info.dur))s")
                    r.append("   阿里: words=\(res.words.count) 句子=\(res.rawSentences.count) 其中含内部句末标点(run-on)=\(runOns)")
                    for s in res.rawSentences.prefix(3) {
                        r.append("     [\(String(format: "%.1f", s.start))-\(String(format: "%.1f", s.end))] \(s.text.prefix(50))")
                    }
                } catch {
                    r.append("· \(info.name.prefix(22)) 失败: \(error.localizedDescription)")
                }
                try? FileManager.default.removeItem(at: pcm)
            }
            r.append("[done]")
            write(outPath, r)
        }
    }

    // MARK: - 阿里 paraformer ASR 单分镜重提取实跑（真实云端，验证 WS 协议）

    @MainActor
    static func runASR(container: ModelContainer) {
        let outPath = ProcessInfo.processInfo.environment["MIXCUT_SELFTEST_OUT"]
            ?? NSTemporaryDirectory() + "mixcut_asr.txt"
        let ctx = container.mainContext
        guard let videos = try? ctx.fetch(FetchDescriptor<Video>()),
              let video = videos.first(where: { !$0.segments.isEmpty && !$0.localPath.isEmpty
                  && FileManager.default.fileExists(atPath: $0.localPath) }) else {
            write(outPath, ["无带分镜的视频"]); return
        }
        let segs = video.segments.sorted { $0.segmentIndex < $1.segmentIndex }
        let targets = Array(segs.prefix(3))   // 验前 3 个分镜
        write(outPath, ["# 阿里 paraformer ASR 单分镜重提取实跑", "视频: \(video.name)", "[运行中…]"])

        let ff = FFmpegRunner()
        let asr = QwenASRClient()
        Task.detached {
            var r = ["# 阿里 paraformer ASR 单分镜重提取实跑(完成)", "视频: \(video.name)"]
            let fps = await MainActor.run { video.fps > 0 ? video.fps : 30 }
            for seg in targets {
                let (idx, sf, ef, whisper) = await MainActor.run {
                    (seg.segmentIndex, seg.startFrame, seg.endFrame, seg.text)
                }
                let start = Double(sf) / fps, end = Double(ef) / fps
                let pcm = FileHelper.tempDirectory.appendingPathComponent("asrtest-\(UUID().uuidString).pcm")
                do {
                    try await ff.extractSegmentPCM(from: video.localPath, start: start, end: end, to: pcm.path)
                    let text = try await asr.transcribe(pcmPath: pcm.path)
                    r.append("· \(idx) [\(String(format: "%.1f", start))-\(String(format: "%.1f", end))s]")
                    r.append("   whisper原: \(whisper.prefix(40))")
                    r.append("   阿里ASR : \(text.prefix(40))")
                } catch {
                    r.append("· \(idx) 失败: \(error.localizedDescription)")
                }
                try? FileManager.default.removeItem(at: pcm)
            }
            r.append("[done]")
            write(outPath, r)
        }
    }

    // MARK: - G1 一键改写实跑（真实云端）

    @MainActor
    static func runRewrite(container: ModelContainer) {
        let outPath = ProcessInfo.processInfo.environment["MIXCUT_SELFTEST_OUT"]
            ?? NSTemporaryDirectory() + "mixcut_rewrite.txt"
        let ctx = container.mainContext
        guard let videos = try? ctx.fetch(FetchDescriptor<Video>()), !videos.isEmpty else {
            write(outPath, ["无视频"]); return
        }
        // 优先选「已克隆且已有配音」的视频(ea30b31，避免重跑 demucs / 选到半成品克隆)，按已有配音数取最多
        func dubCount(_ v: Video) -> Int { v.segments.flatMap(\.segmentDubs).count }
        let video = videos.filter { ($0.clonedVoiceId ?? "").isEmpty == false && dubCount($0) > 0 }
            .max { dubCount($0) < dubCount($1) }
            ?? videos.max { dubCount($0) < dubCount($1) }!
        let before = video.segments.flatMap(\.segmentDubs).count
        let n = DubbingViewModel().variantCount
        write(outPath, ["# G1 一键改写实跑", "视频: \(video.name)", "改写前变体数: \(before)，每镜变体设置: \(n)", "[运行中…]"])
        let vm = DubbingViewModel()
        Task { @MainActor in
            await vm.rewriteAll(video: video, context: ctx)
            let dubs = video.segments.flatMap(\.segmentDubs)
            let withAudio = dubs.filter { $0.audioFilePath != nil }.count
            let cloned = video.clonedVoiceId ?? "nil"
            var r = ["# G1 一键改写实跑(完成)", "视频: \(video.name)",
                     "克隆音色: \(cloned)",
                     "改写后变体总数: \(dubs.count)，其中有音频: \(withAudio)",
                     "非锁定分镜数: \(video.segments.filter { !$0.isVoiceLocked && !$0.text.isEmpty }.count)，每镜应产: \(n)"]
            if let err = vm.errorMessage { r.append("errorMessage: \(err)") }
            // 各分镜每条配音的时长对齐情况：分镜时长 D / 配音时长 / 末尾空挡静音
            for s in video.segments.sorted(by: { $0.segmentIndex < $1.segmentIndex }) {
                let dur = s.duration
                r.append("  \(s.segmentIndex) 分镜=\(String(format: "%.2f", dur))s locked=\(s.isVoiceLocked) 有效变体=\(s.effectiveDubVariants.count)")
                for d in s.effectiveDubVariants {
                    let gap = dur - d.audioDuration
                    r.append("     变体\(d.textVariantIndex) 配音=\(String(format: "%.2f", d.audioDuration))s 空挡=\(String(format: "%.2f", max(0, gap)))s atempo=\(String(format: "%.2f", d.atempoFactor)) 末尾静音=\(String(format: "%.2f", d.trailingSilence))s")
                }
            }
            r.append("[done]")
            write(outPath, r)
        }
    }

    // MARK: - G3 方案生成实跑（临时项目，跑完即删，不污染真实数据）

    @MainActor
    static func runGenSchemes(container: ModelContainer, target: Int) {
        let outPath = ProcessInfo.processInfo.environment["MIXCUT_SELFTEST_OUT"]
            ?? NSTemporaryDirectory() + "mixcut_gen.txt"
        let ctx = container.mainContext
        guard let videos = try? ctx.fetch(FetchDescriptor<Video>()),
              let video = videos.max(by: { $0.segments.flatMap(\.segmentDubs).count < $1.segments.flatMap(\.segmentDubs).count }) else {
            write(outPath, ["无视频"]); return
        }
        // 临时项目（链接同一视频，全局共享）
        let temp = Project(name: "【自检临时】请忽略")
        temp.status = .ready
        ctx.insert(temp)
        let pv = ProjectVideo(project: temp, video: video)
        ctx.insert(pv)
        try? ctx.save()
        let tempId = temp.id
        write(outPath, ["# G3 方案生成实跑(临时项目)", "目标视频数: \(target)", "[运行中…]"])

        let vm = SchemeViewModel()
        vm.setModelContext(ctx)
        Task { @MainActor in
            await vm.generateSchemes(for: temp, targetVideoCount: target)
            // 统计三层
            let ai = vm.aiStrategies
            let allSchemes = ai.flatMap(\.orderedSchemes)
            let groups = Set(allSchemes.compactMap { $0.templateGroupId })
            let variantNamed = allSchemes.filter { $0.name.contains("变体") }.count
            var r = ["# G3 方案生成实跑(完成,临时项目)",
                     "进度文案: \(vm.generationProgress)",
                     "AI策略数: \(ai.count)",
                     "模板组数(templateGroupId 去重): \(groups.count)",
                     "变体视频总数: \(allSchemes.count)，命名含「变体」: \(variantNamed)"]
            if let err = vm.errorMessage { r.append("errorMessage: \(err)") }
            // 抽一个模板组看其变体的 selectedSegmentDubId 是否各异
            if let g = groups.first {
                let inGroup = allSchemes.filter { $0.templateGroupId == g }
                r.append("样例模板组变体数: \(inGroup.count)")
                for sc in inGroup.prefix(4) {
                    let dubIds = sc.orderedSegments.compactMap { $0.selectedSegmentDubId?.uuidString.prefix(6) }
                    r.append("  变体#\(sc.templateVariantIndex) name=\(sc.name) dubs=\(dubIds.joined(separator: ","))")
                }
            }
            // —— 清理临时项目(删 strategies/schemes/schemeSegments/projectVideo/project) ——
            if let schemes = try? ctx.fetch(FetchDescriptor<MixScheme>()) {
                for sc in schemes where sc.project?.id == tempId { ctx.delete(sc) }
            }
            if let strats = try? ctx.fetch(FetchDescriptor<MixStrategy>()) {
                for st in strats where st.project?.id == tempId { ctx.delete(st) }
            }
            if let pvs = try? ctx.fetch(FetchDescriptor<ProjectVideo>()) {
                for p in pvs where p.project?.id == tempId { ctx.delete(p) }
            }
            if let projs = try? ctx.fetch(FetchDescriptor<Project>()) {
                for p in projs where p.id == tempId { ctx.delete(p) }
            }
            try? ctx.save()
            r.append("[临时项目已清理]")
            r.append("[done]")
            write(outPath, r)
        }
    }

    private static func ffmpegProbe(_ path: String) -> String {
        guard let bin = Bundle.main.resourceURL?.appendingPathComponent("bin/ffmpeg").path,
              FileManager.default.fileExists(atPath: bin) else { return "(无 ffmpeg)" }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: bin)
        p.arguments = ["-i", path]
        let pipe = Pipe()
        p.standardError = pipe
        p.standardOutput = Pipe()
        do { try p.run(); p.waitUntilExit() } catch { return "(probe 失败: \(error))" }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let s = String(data: data, encoding: .utf8) ?? ""
        return s.split(separator: "\n").filter { $0.contains("Duration") || $0.contains("Stream") }
            .joined(separator: "\n")
    }

    private static func write(_ path: String, _ lines: [String]) {
        try? lines.joined(separator: "\n").write(toFile: path, atomically: true, encoding: .utf8)
    }
}
#endif
