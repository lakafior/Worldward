/// This Source Code Form is subject to the terms of the Mozilla Public License, v. 2.0. If a copy of the MPL was not distributed with this file, You can obtain one at https://mozilla.org/MPL/2.0/.

import SwiftUI
import Translation

/// A small, reusable bridge to Apple's Translation framework for translating
/// on-device LLM output (which is always generated in English) into the user's
/// language. The on-device language model is a poor translator, so generation
/// stays English and this turns the result into the device language using the
/// same high-quality models as the Translate app.
///
/// Usage: keep one as `@State` in a view, attach `.appTranslation(translator)` to
/// that view, then `await translator.translate(text)` after generating English.
/// It returns the originals unchanged when the app already runs in English or when
/// the language pair isn't supported, so callers never need to special-case that.
@MainActor
@Observable
final class AppTranslator {

    /// Drives `.translationTask`; set the first time and invalidated thereafter so
    /// the task re-runs with fresh content using the same language pair.
    private(set) var configuration: TranslationSession.Configuration?

    /// Strings awaiting translation, handed to the translation task.
    private var pending: [String]?
    /// Resumed with the translated strings once the task completes.
    private var continuation: CheckedContinuation<[String], Never>?
    /// The language pair the current `configuration` was built for, so a same-pair
    /// request re-runs via `invalidate()` while a direction change makes a fresh one.
    private var activePair: String?

    private static let english = Locale.Language(identifier: "en")
    private static var device: Locale.Language { Locale.current.language }

    /// `true` when the app runs in a non-English language, so translation is worth
    /// doing. English stays as-is (the model already speaks English).
    static var isNeeded: Bool {
        (Locale.current.language.languageCode?.identifier ?? "en") != "en"
    }

    /// Translates `texts` between the given languages, preserving order and count.
    /// Returns the originals unchanged when translation fails — so a flaky or
    /// unsupported language never drops content.
    func translate(_ texts: [String], from source: Locale.Language, to target: Locale.Language)
        async -> [String]
    {
        guard !texts.isEmpty else { return texts }

        // Release any stale waiter (shouldn't happen with sequential UI use, but
        // avoids a leaked continuation hanging forever).
        continuation?.resume(returning: pending ?? texts)
        continuation = nil

        pending = texts
        let pair = "\(source.languageCode?.identifier ?? "?")>\(target.languageCode?.identifier ?? "?")"
        if configuration != nil, activePair == pair {
            // Same languages, new content: re-run the existing session.
            configuration?.invalidate()
        } else {
            // First run, or a direction change: build a fresh session.
            configuration = TranslationSession.Configuration(source: source, target: target)
            activePair = pair
        }
        return await withCheckedContinuation { continuation = $0 }
    }

    /// Translates English text into the device language (no-op when English).
    func translate(_ texts: [String]) async -> [String] {
        guard Self.isNeeded else { return texts }
        return await translate(texts, from: Self.english, to: Self.device)
    }

    /// Convenience for a single string (e.g. a recap or a chat answer).
    func translate(_ text: String) async -> String {
        await translate([text]).first ?? text
    }

    /// Translates a single string from the device language into English — used to
    /// feed user input to an English-centric model (no-op when already English).
    func toEnglish(_ text: String) async -> String {
        guard Self.isNeeded else { return text }
        return await translate([text], from: Self.device, to: Self.english).first ?? text
    }

    /// Reads and clears the pending texts. Called from the (nonisolated) task.
    fileprivate func takePending() -> [String]? {
        defer { pending = nil }
        return pending
    }

    /// Resumes the awaiting `translate(_:)` call with its results.
    fileprivate func finish(with results: [String]) {
        let waiting = continuation
        continuation = nil
        waiting?.resume(returning: results)
    }
}

extension View {
    /// Attaches the translation task that powers `AppTranslator.translate(_:)`.
    /// The session isn't `Sendable`, so the closure is `@Sendable` (nonisolated) and
    /// uses the session in place, hopping to the main actor only for state.
    func appTranslation(_ translator: AppTranslator) -> some View {
        translationTask(translator.configuration) { @Sendable session in
            guard let texts = await translator.takePending() else { return }
            var results = texts
            do {
                let requests = texts.map { TranslationSession.Request(sourceText: $0) }
                let responses = try await session.translations(from: requests)
                if responses.count == texts.count {
                    results = responses.map(\.targetText)
                }
            } catch {
                // Keep English originals if the language pair is unavailable.
            }
            await translator.finish(with: results)
        }
    }
}
