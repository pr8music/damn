//
//  VoiceOutputClient.swift
//  leanring-buddy
//
//  Free text-to-speech using the voices built into macOS. No network needed.
//
//  Voice choice, in order:
//    1. A voice you name: CLICKY_VOICE environment variable (or `defaults write
//       <bundle id> ClickyVoice "Zoe"`). Any part of the voice name works.
//    2. Otherwise the highest-quality installed voice for your language, so a
//       Premium or Enhanced voice you downloaded is picked automatically.
//       (Download in System Settings > Accessibility > Spoken Content >
//       System Voice > Manage Voices.)
//    3. If a voice stays silent, Clicky retries once with the plain system voice.
//
//  The console shows which voice is speaking (look for the 🔊 lines).
//

import AVFoundation
import Foundation

/// A piece of speech ready to play. (Kept as a separate type so the step player
/// can queue up the next step while the current one is speaking.)
struct PreparedSpeech {
    let text: String
}

@MainActor
final class VoiceOutputClient {

    private let synthesizer = AVSpeechSynthesizer()
    private let preferredVoiceName: String?

    init() {
        let environment = ProcessInfo.processInfo.environment
        let configuredName = environment["CLICKY_VOICE"] ?? UserDefaults.standard.string(forKey: "ClickyVoice")
        let trimmedName = configuredName?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.preferredVoiceName = (trimmedName?.isEmpty == false) ? trimmedName : nil

        let voice = Self.pickVoice(preferredName: preferredVoiceName)
        print("🔊 Voice: Apple voice \"\(voice?.name ?? "system default")\" (quality \(voice?.quality.rawValue ?? 0), language \(voice?.language ?? "?"))")
    }

    // MARK: - Public API

    /// Whether speech is currently playing.
    var isPlaying: Bool {
        synthesizer.isSpeaking
    }

    /// Stops speech immediately.
    func stopPlayback() {
        if synthesizer.isSpeaking {
            synthesizer.stopSpeaking(at: .immediate)
        }
    }

    /// Returns right away. (Apple voices need no preparation; this exists so the
    /// step player can treat every voice the same way.)
    func prepareSpeech(_ rawText: String) -> Task<PreparedSpeech, Never> {
        let text = Self.cleanForSpeech(rawText)
        return Task<PreparedSpeech, Never> { PreparedSpeech(text: text) }
    }

    /// Speaks the text and returns when it has finished (or the task is cancelled).
    func play(_ prepared: PreparedSpeech) async {
        guard !prepared.text.isEmpty else { return }
        stopPlayback()

        let chosenVoice = Self.pickVoice(preferredName: preferredVoiceName)
        if await speakAndWait(prepared.text, voice: chosenVoice) {
            return
        }
        guard !Task.isCancelled else { return }

        // The chosen voice never started (some downloaded voices can be silent
        // until macOS finishes setting them up). Try the plain system voice.
        print("⚠️ Voice \"\(chosenVoice?.name ?? "default")\" stayed silent, retrying with the system voice")
        let systemVoice = AVSpeechSynthesisVoice(language: AVSpeechSynthesisVoice.currentLanguageCode())
        _ = await speakAndWait(prepared.text, voice: systemVoice)
    }

    // MARK: - Speaking

    /// Returns true if speech started (and has now finished or been cancelled).
    private func speakAndWait(_ text: String, voice: AVSpeechSynthesisVoice?) async -> Bool {
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = voice
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate
        synthesizer.speak(utterance)

        // isSpeaking can lag a moment behind speak(), so wait up to one second.
        var startupChecks = 0
        while !synthesizer.isSpeaking && startupChecks < 40 {
            if Task.isCancelled {
                synthesizer.stopSpeaking(at: .immediate)
                return true
            }
            try? await Task.sleep(nanoseconds: 25_000_000)
            startupChecks += 1
        }

        guard synthesizer.isSpeaking else {
            synthesizer.stopSpeaking(at: .immediate)
            return false
        }

        while synthesizer.isSpeaking {
            if Task.isCancelled {
                synthesizer.stopSpeaking(at: .immediate)
                return true
            }
            try? await Task.sleep(nanoseconds: 60_000_000)
        }
        return true
    }

    // MARK: - Voice choice

    private static func pickVoice(preferredName: String?) -> AVSpeechSynthesisVoice? {
        let languageCode = AVSpeechSynthesisVoice.currentLanguageCode()
        let languagePrefix = languageCode.split(separator: "-").first.map(String.init) ?? languageCode

        // Skip the old novelty voices (Albert, Bad News, Bells, Zarvox ...).
        let allVoices = AVSpeechSynthesisVoice.speechVoices().filter {
            !$0.identifier.contains("speech.synthesis.voice")
        }

        // 1. A voice the user asked for by name.
        if let preferredName = preferredName?.lowercased(),
           let namedVoice = allVoices.first(where: { $0.name.lowercased().contains(preferredName) }) {
            return namedVoice
        }

        // 2. Best quality voice for the exact language (en-US), then the broader one (en).
        let exactLanguageVoices = allVoices.filter { $0.language == languageCode }
        let broaderLanguageVoices = allVoices.filter { $0.language.hasPrefix(languagePrefix) }

        for candidates in [exactLanguageVoices, broaderLanguageVoices] {
            if let best = candidates.max(by: { $0.quality.rawValue < $1.quality.rawValue }) {
                return best
            }
        }

        return AVSpeechSynthesisVoice(language: languageCode)
    }

    // MARK: - Text cleanup

    /// Removes leftover tags and markdown symbols that sound odd when spoken.
    private static func cleanForSpeech(_ text: String) -> String {
        var result = text

        if let tagRegex = try? NSRegularExpression(pattern: "\\[(POINT|DRAW|DIAGRAM):[^\\]]*\\]", options: [.caseInsensitive]) {
            let fullRange = NSRange(result.startIndex..., in: result)
            result = tagRegex.stringByReplacingMatches(in: result, range: fullRange, withTemplate: "")
        }

        result = result
            .replacingOccurrences(of: "**", with: "")
            .replacingOccurrences(of: "`", with: "")

        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
