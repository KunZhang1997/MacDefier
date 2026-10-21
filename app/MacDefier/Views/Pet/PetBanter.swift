// Mr. Defier occasional speech.
// Rules (user):
// • Language = **app Settings only** (中文 / English). Never OS preferredLanguages.
// • No 人设/personality pool for now.
// • Drama-style lines gated (5 min prod / shorter in test).
// • Never scare-copy.

import Foundation

enum PetBanterLanguage: Equatable {
    case chinese
    case english
    // resolve() / fromSystem() live in AppLanguage.swift so Settings + banter share one source.
}

enum PetBanter {
    // MARK: - Timing

    // MARK: Timing — production：偶尔冒一句，不刷屏（QA 测试参数已还原）
    static let initialDelayRange: ClosedRange<Double> = 10...20
    static let attemptIntervalRange: ClosedRange<Double> = 45...90
    static let speakProbability: Double = 0.4
    /// How long the bubble stays visible (seconds). Longer so it doesn’t flash away.
    static let displayDuration: Double = 8.0
    /// Min seconds between any two spoken lines.
    static let hardCooldown: Double = 55
    static let moodAnnounceProbability: Double = 0.7
    /// Drama pool: at most once per this interval.
    static let dramaCooldown: TimeInterval = 5 * 60
    /// Chance to try drama when eligible (idle/happy, cooldown ok).
    static let dramaPickProbability: Double = 0.5

    private static let lastDramaAtKey = "pet.banter.lastDramaAt"

    // MARK: - Public API

    /// Pick a line for current mood. Language from app Settings only.
    static func line(for mood: PetMood, highFindings: Int = 0) -> String {
        let lang = PetBanterLanguage.resolve()
        return line(for: mood, highFindings: highFindings, language: lang)
    }

    static func line(for mood: PetMood, highFindings: Int = 0, language: PetBanterLanguage) -> String {
        // Generic alert nudge when highs exist but no specific finding line was chosen
        if highFindings > 0, mood == .alert || mood == .idle {
            if Double.random(in: 0...1) < 0.55 {
                return pick(statusAlert(language), fallback: fallback(language))
            }
        }

        if (mood == .idle || mood == .happy),
           canSpeakDrama(),
           Double.random(in: 0...1) < dramaPickProbability,
           let d = drama(language).randomElement() {
            markDramaSpoken()
            return d
        }

        return pick(status(for: mood, language: language), fallback: fallback(language))
    }

    // MARK: - Business lines (existing modules → full sentences)

    /// Diagnostic finding (prefer high/warn title).
    static func line(forFinding f: DiagnosticFinding, language: PetBanterLanguage) -> String {
        let title = f.title.trimmingCharacters(in: .whitespacesAndNewlines)
        let short = title.count > 22 ? String(title.prefix(20)) + "…" : title
        switch language {
        case .chinese:
            switch f.severity {
            case .high:
                return "有件事比较急：\(short)，有空点开看看？"
            case .warn:
                return "提一句：\(short)，不急也行。"
            case .info:
                return "顺带说一声：\(short)。"
            }
        case .english:
            switch f.severity {
            case .high:
                return "Heads-up: \(short). Worth a quick look."
            case .warn:
                return "Just noting: \(short)."
            case .info:
                return "FYI: \(short)."
            }
        }
    }

    static func lineCleanup(bytes: UInt64, language: PetBanterLanguage) -> String {
        let gb = Double(bytes) / 1_073_741_824
        let size = gb >= 1
            ? String(format: "%.1f GB", gb)
            : String(format: "%.0f MB", Double(bytes) / 1_048_576)
        switch language {
        case .chinese:
            return "大概有 \(size) 能腾出来，要不要打开清理页瞅一眼？"
        case .english:
            return "About \(size) you could free up — want to open Cleanup?"
        }
    }

    static func lineMonitorPressure(cpu: Double, ram: Double, language: PetBanterLanguage) -> String {
        let cpuPct = Int((cpu * 100).rounded())
        let ramPct = Int((ram * 100).rounded())
        switch language {
        case .chinese:
            if cpu >= 0.88 {
                return "电脑有点忙（占用大约 \(cpuPct)%），要看看是谁在跑吗？"
            }
            if ram >= 0.90 {
                return "内存有点吃紧（大约 \(ramPct)%），要不要看一眼在跑什么？"
            }
            return "电脑最近有点喘，要不要打开监控看看？"
        case .english:
            if cpu >= 0.88 {
                return "Your Mac’s been busy (~\(cpuPct)%). Want to see who’s working?"
            }
            if ram >= 0.90 {
                return "Memory’s a bit tight (~\(ramPct)%). Peek at what’s running?"
            }
            return "Things feel a bit heavy — open Monitor when you can."
        }
    }

    static func linePendingUninstall(name: String, language: PetBanterLanguage) -> String {
        let n = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let short = n.isEmpty ? (language == .chinese ? "那个软件" : "an app") : n
        switch language {
        case .chinese:
            return "\(short) 这边还有一步，打开软件页就能接着弄。"
        case .english:
            return "Still one step left for \(short) — open Software when ready."
        }
    }

    static func canSpeakDrama(now: Date = Date()) -> Bool {
        let last = UserDefaults.standard.double(forKey: lastDramaAtKey)
        if last <= 0 { return true }
        return now.timeIntervalSince1970 - last >= dramaCooldown
    }

    static func markDramaSpoken(now: Date = Date()) {
        UserDefaults.standard.set(now.timeIntervalSince1970, forKey: lastDramaAtKey)
    }

    // MARK: - Status (no 人设)

    private static func status(for mood: PetMood, language: PetBanterLanguage) -> [String] {
        switch mood {
        case .idle: return statusIdle(language)
        case .alert: return statusAlert(language)
        case .scan: return statusScan(language)
        case .sleep: return statusSleep(language)
        case .happy: return statusHappy(language)
        case .talk: return statusTalk(language)
        }
    }

    private static func statusIdle(_ lang: PetBanterLanguage) -> [String] {
        switch lang {
        case .chinese:
            return [
                "挺好的，暂时没事。",
                "看着还行，我先帮你盯着。",
                "我就在这儿，有事喊我。",
                "电脑挺安静，我也歇会儿。",
                "先看着，不瞎折腾。"
            ]
        case .english:
            return [
                "All good for now.",
                "Looks fine — I’ve got an eye on it.",
                "I’m here if you need me.",
                "Mac’s quiet, so am I.",
                "Watching quietly. No rush."
            ]
        }
    }

    private static func statusAlert(_ lang: PetBanterLanguage) -> [String] {
        switch lang {
        case .chinese:
            return [
                "有点小事想跟你说，空了看一眼就好。",
                "有一件事值得瞄一眼，不急着吓你。",
                "我帮你记着一件事，点开就能看。",
                "提个醒而已，忙完再处理也行。",
                "处理完会更轻松一点，有空来一下。"
            ]
        case .english:
            return [
                "Small thing when you have a sec.",
                "One item worth a glance — no panic.",
                "I left a note for you; open when ready.",
                "Just a gentle nudge, no rush.",
                "It’ll feel lighter after a quick look."
            ]
        }
    }

    private static func statusScan(_ lang: PetBanterLanguage) -> [String] {
        switch lang {
        case .chinese:
            return [
                "我在帮你瞅一眼，别慌。",
                "正在看，马上说结果。",
                "还在查，稍等我一下。",
                "先看清楚，再决定动不动手。"
            ]
        case .english:
            return [
                "Taking a look — no stress.",
                "Checking now; back in a sec.",
                "Still looking — hang on.",
                "Figure out the why first, then we act."
            ]
        }
    }

    private static func statusSleep(_ lang: PetBanterLanguage) -> [String] {
        // sleep 态保留给未来真休眠；现 AI 关走 lineAISetup，不再「闭眼打盹」
        lineAISetupPool(lang)
    }

    /// AI 关 / 未配接口：提示去设置填 API Key（睁眼灰宠配套话术）
    static func lineAISetup(language: PetBanterLanguage) -> String {
        lineAISetupPool(language).randomElement()!
    }

    private static func lineAISetupPool(_ lang: PetBanterLanguage) -> [String] {
        switch lang {
        case .chinese:
            return [
                "AI 先关着。要点对话，去设置填 API Key。",
                "想聊一句？设置里开 AI、填上 Key 就行。",
                "清理不用 AI；闲聊要 API Key，点我或进设置。",
                "我还在岗，只是没接模型。设置 → 填 Key。",
                "灰色是没开 AI。去设置配 Key，就能聊。"
            ]
        case .english:
            return [
                "AI is off. Add an API Key in Settings to chat.",
                "Want to talk? Turn on AI and paste your Key.",
                "Cleanup works without AI; chat needs a Key.",
                "Still here — no model yet. Settings → API Key.",
                "Gray means AI is off. Configure a Key to chat."
            ]
        }
    }

    private static func statusHappy(_ lang: PetBanterLanguage) -> [String] {
        switch lang {
        case .chinese:
            return [
                "对话框开了，有事直接说。",
                "我在呢，慢慢说就行。",
                "你来了，我听着。"
            ]
        case .english:
            return [
                "Chat’s open — fire away.",
                "I’m here. Take your time.",
                "You opened up; I’m listening."
            ]
        }
    }

    private static func statusTalk(_ lang: PetBanterLanguage) -> [String] {
        switch lang {
        case .chinese:
            return [
                "我想想，稍等一下。",
                "等我捋一捋再说。",
                "正在看你的问题，马上好。"
            ]
        case .english:
            return [
                "Thinking — one sec.",
                "Hang on, putting it together.",
                "On it — almost there."
            ]
        }
    }

    // MARK: - Drama (locale-matched; max 1 / 5 min)

    /// Soft pastiche of viral drama/net rhythm — product-safe, no scare copy.
    private static func drama(_ lang: PetBanterLanguage) -> [String] {
        switch lang {
        case .chinese:
            return [
                "记住哦：先看清楚，再动手清。",
                "主打一个不吓人、也不假加速。",
                "好家伙，缓存又想住大房子了。",
                "卡的话，先瞅瞅是谁在忙。",
                "有空就顺手清一清，轻松点。",
                "垃圾先丢进废纸篓，别硬删。",
                "慢一点。想明白了再点确认。",
                "本豆在岗，有事喊一声。",
                "先问为什么卡，再谈怎么清。",
                "忙可以，瞎忙就算了。"
            ]
        case .english:
            return [
                "Look first, clean second.",
                "No scare scans. No fake speed-ups.",
                "Caches building little condos again.",
                "Laggy? See who’s busy first.",
                "A little tidy-up when you can.",
                "Trash goes to the Bin — always.",
                "Slow is fine. Blind cleaning isn’t.",
                "On duty. Just holler.",
                "Find the why, then the fix.",
                "Busy is fine. Chaos isn’t."
            ]
        }
    }

    private static func fallback(_ lang: PetBanterLanguage) -> String {
        lang == .chinese ? "挺好的，暂时没事。" : "All good for now."
    }

    private static func pick(_ lines: [String], fallback: String) -> String {
        lines.randomElement() ?? fallback
    }
}
