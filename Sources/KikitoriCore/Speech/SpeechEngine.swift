import Foundation

/// An on-device speech-to-text engine. Input is one chunk of 16 kHz mono audio.
public protocol SpeechEngine: Sendable {
    var name: String { get }
    /// Download or load whatever the engine needs. Safe to call more than once.
    func prepare() async throws
    /// Japanese text for one chunk. `context` is a few recent words or glossary terms the
    /// engine may use to bias recognition (names), if it supports that.
    func transcribe(_ samples: [Float], context: [String]) async throws -> String
}

/// Cleans engine output: drops phrases speech models invent over silence or music, and
/// collapses repetition loops ("いいいいいい…", "はいはいはいはい…").
public enum TranscriptFilter {
    static let invented = [
        "ご視聴ありがとうございました", "ご視聴ありがとうございます", "チャンネル登録よろしくお願いします",
        "チャンネル登録お願いします", "次回予告", "字幕は視聴者によって作成されました",
        "おやすみなさい。", "お疲れ様でした。",
    ]

    public static func clean(_ text: String) -> String {
        var s = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let bare = s.trimmingCharacters(in: CharacterSet(charactersIn: "。、！？!?.・ 　"))
        if invented.contains(where: { bare == $0.trimmingCharacters(in: CharacterSet(charactersIn: "。")) }) { return "" }
        s = collapseRepeats(s)
        return s
    }

    /// Any unit of 1–6 characters repeated more than 4 times in a row is cut to 4 repeats.
    static func collapseRepeats(_ s: String) -> String {
        let chars = Array(s)
        var out: [Character] = []
        var i = 0
        while i < chars.count {
            var collapsed = false
            for unit in 1...6 where i + unit * 5 <= chars.count {
                let piece = chars[i..<i + unit]
                var reps = 1
                while i + (reps + 1) * unit <= chars.count, chars[i + reps * unit..<i + (reps + 1) * unit] == piece {
                    reps += 1
                }
                if reps > 4 {
                    for _ in 0..<4 { out += piece }
                    i += reps * unit
                    collapsed = true
                    break
                }
            }
            if !collapsed { out.append(chars[i]); i += 1 }
        }
        return String(out)
    }
}
