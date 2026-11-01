//
//  AppleTTSClient.swift
//  leanring-buddy
//
//  Free replacement for ElevenLabsTTSClient. Same interface (speakText,
//  isPlaying, stopPlayback) but uses the voices built into macOS.
//
//  Tip: for a much nicer sound, download an Enhanced or Premium voice in
//  System Settings > Accessibility > Spoken Content > System Voice > Manage Voices.
//  This client automatically picks the best installed voice for your language.
//

import AVFoundation
import Foundation

@MainActor
final class AppleTTSClient {
    private let synthesizer = AVSpeechSynthesizer()

    /// Speaks `text` out loud. Returns as soon as speech has started,
    /// just like ElevenLabsTTSClient.speakText does after player.play().
    func speakText(_ text: String) async throws {
        let cleanedText = Self.cleanForSpeech(text)
        guard !cleanedText.isEmpty else { return }

        try Task.checkCancellation()

        stopPlayback()

        let utterance = AVSpeechUtterance(string: cleanedText)
        utterance.voice = Self.bestAvailableVoice()
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate
        synthesizer.speak(utterance)
        print("🔊 Apple TTS: speaking \(cleanedText.count) characters")
    }

    /// Whether speech is currently being played.
    var isPlaying: Bool {
        synthesizer.isSpeaking
    }

    /// Stops any in-progress speech immediately.
    func stopPlayback() {
        if synthesizer.isSpeaking {
            synthesizer.stopSpeaking(at: .immediate)
        }
    }

    // MARK: - Helpers

    /// Removes leftover markdown symbols and point tags that sound odd when spoken.
    private static func cleanForSpeech(_ text: String) -> String {
        var result = text

        if let pointTagRegex = try? NSRegularExpression(pattern: "\\[POINT:[^\\]]*\\]") {
            let fullRange = NSRange(result.startIndex..., in: result)
            result = pointTagRegex.stringByReplacingMatches(
                in: result,
                range: fullRange,
                withTemplate: ""
            )
        }

        result = result
            .replacingOccurrences(of: "**", with: "")
            .replacingOccurrences(of: "`", with: "")

        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func bestAvailableVoice() -> AVSpeechSynthesisVoice? {
        let languageCode = AVSpeechSynthesisVoice.currentLanguageCode()
        let matchingVoices = AVSpeechSynthesisVoice.speechVoices().filter { $0.language == languageCode }
        return matchingVoices.max(by: { $0.quality.rawValue < $1.quality.rawValue })
            ?? AVSpeechSynthesisVoice(language: languageCode)
    }
}
