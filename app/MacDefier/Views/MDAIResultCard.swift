// MDAIResultCard — shared AI review card (Cleanup + Software). U2 + U4.

import SwiftUI

/// Max height for card body (~5–6 lines); taller content scrolls inside the card.
private let mdAIResultBodyMaxHeight: CGFloat = 180

struct MDAIResultCard: View {
    let text: String

    var body: some View {
        let blocks = MDAITextBlocks.blocks(from: stripAIPrefix(text))
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "sparkles")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(MDTheme.accent)
                Text(L10n.t("common.ai_review"))
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(MDTheme.accent)
            }

            // U4: body height-capped + internal scroll
            ScrollView(.vertical, showsIndicators: true) {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                        HStack(alignment: .top, spacing: 8) {
                            if let label = block.label {
                                Text(label)
                                    .font(.system(size: 11, weight: .semibold))
                                    .foregroundStyle(MDTheme.accent)
                                    .frame(width: 56, alignment: .leading)
                            } else {
                                Circle()
                                    .fill(MDTheme.accent.opacity(0.55))
                                    .frame(width: 5, height: 5)
                                    .padding(.top, 6)
                            }
                            Text(block.body)
                                .font(.system(size: 12.5))
                                .foregroundStyle(MDTheme.label)
                                .fixedSize(horizontal: false, vertical: true)
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .padding(.vertical, 2)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: mdAIResultBodyMaxHeight, alignment: .top)
            .mask(
                // Soft fade when content is tall (hint more below)
                LinearGradient(
                    stops: [
                        .init(color: .black, location: 0),
                        .init(color: .black, location: 0.88),
                        .init(color: .black.opacity(0.15), location: 1)
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
            )
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(MDTheme.accent.opacity(0.06), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private func stripAIPrefix(_ raw: String) -> String {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix("【AI】") {
            s = String(s.dropFirst(4)).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if s.hasPrefix("[AI]") {
            s = String(s.dropFirst(4)).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return s
    }
}

// MARK: - Text block parser (moved from SoftwareView / SoftwareAIDisplay)

enum MDAITextBlocks {
    struct Block: Equatable {
        var label: String?
        var body: String
    }

    /// Prefer labeled lines; otherwise split by newline / sentence.
    static func blocks(from raw: String) -> [Block] {
        let cleaned = raw
            .replacingOccurrences(of: "\r\n", with: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return [] }

        let lines = cleaned
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }

        let labeled = lines.compactMap { labeledBlock($0) }
        if labeled.count >= 2, labeled.count >= (lines.count + 1) / 2 {
            return labeled
        }

        if lines.count >= 2 {
            return lines.flatMap { expandLongLine($0) }
        }

        return expandLongLine(cleaned)
    }

    private static func labeledBlock(_ line: String) -> Block? {
        var s = line
        if s.hasPrefix("- ") || s.hasPrefix("• ") || s.hasPrefix("* ") {
            s = String(s.dropFirst(2)).trimmingCharacters(in: .whitespaces)
        }
        if let r = s.range(of: #"^\d+[\.\)、]\s*"#, options: .regularExpression) {
            s = String(s[r.upperBound...]).trimmingCharacters(in: .whitespaces)
        }
        guard let colon = s.firstIndex(of: "：") ?? s.firstIndex(of: ":") else { return nil }
        let label = String(s[..<colon]).trimmingCharacters(in: .whitespaces)
        let body = String(s[s.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
        guard label.count >= 2, label.count <= 12, !body.isEmpty else { return nil }
        if label.contains("http") || label.contains("//") { return nil }
        return Block(label: label, body: body)
    }

    private static func expandLongLine(_ line: String) -> [Block] {
        if let labeled = labeledBlock(line) {
            return [labeled]
        }
        if line.count < 90 {
            return [Block(label: nil, body: line)]
        }
        let parts = line
            .replacingOccurrences(of: "！", with: "。")
            .replacingOccurrences(of: "？", with: "。")
            .replacingOccurrences(of: "；", with: "。")
            .components(separatedBy: "。")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        if parts.count >= 2 {
            return parts.map { Block(label: nil, body: $0 + "。") }
        }
        return [Block(label: nil, body: line)]
    }
}

/// AI 短评限高：过长内部滚动，避免撑破监控卡。
struct MDAIClampedText: View {
    let text: String
    var maxHeight: CGFloat = 72

    init(_ text: String, maxHeight: CGFloat = 72) {
        self.text = text
        self.maxHeight = maxHeight
    }

    var body: some View {
        ScrollView(.vertical, showsIndicators: text.count > 120) {
            Text(text)
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
        }
        .frame(maxHeight: maxHeight, alignment: .top)
    }
}
