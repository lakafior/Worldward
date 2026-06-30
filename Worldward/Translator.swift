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

    /// English strings awaiting translation, handed to the translation task.
    private var pending: [String]?
    /// Resumed with the translated strings once the task completes.
    private var continuation: CheckedContinuation<[String], Never>?

    /// `true` when the app runs in a non-English language, so translation is worth
    /// doing. English stays as-is (the model already writes English).
    static var isNeeded: Bool {
        (Locale.current.language.languageCode?.identifier ?? "en") != "en"
    }

    /// Translates `texts` from English into the device language, preserving order
    /// and count. Returns the originals unchanged when translation isn't needed or
    /// fails — so a flaky or unsupported language never drops content.
    func translate(_ texts: [String]) async -> [String] {
        guard Self.isNeeded, !texts.isEmpty else { return texts }

        // Release any stale waiter (shouldn't happen with sequential UI use, but
        // avoids a leaked continuation hanging forever).
        continuation?.resume(returning: pending ?? texts)
        continuation = nil

        pending = texts
        if configuration == nil {
            configuration = TranslationSession.Configuration(
                source: Locale.Language(identifier: "en"), target: Locale.current.language)
        } else {
            configuration?.invalidate()
        }
        return await withCheckedContinuation { continuation = $0 }
    }

    /// Convenience for a single string (e.g. a recap or a chat answer).
    func translate(_ text: String) async -> String {
        await translate([text]).first ?? text
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
