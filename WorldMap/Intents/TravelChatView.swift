import FoundationModels
import SwiftUI

/// A lightweight sheet that lets the user ask free-form questions about their
/// own travels, answered on-device by `TravelIntelligence`. Single question →
/// single answer, with starter-suggestion chips; the session keeps context so
/// follow-ups work too. Falls back gracefully when Apple Intelligence is off or
/// unsupported.
struct TravelChatView: View {
    @State private var intelligence = TravelIntelligence()
    @State private var question = ""
    @FocusState private var fieldFocused: Bool

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Group {
                if intelligence.isAvailable {
                    chatSurface
                } else {
                    unavailableView
                }
            }
            .navigationTitle("Ask About Your Travels")
            #if !os(macOS)
                .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
                if intelligence.isAvailable {
                    ToolbarItem(placement: .cancellationAction) {
                        Button {
                            intelligence.reset()
                            question = ""
                        } label: {
                            Label("New", systemImage: "square.and.pencil")
                        }
                    }
                }
            }
        }
    }

    // MARK: - Available

    private var chatSurface: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    answerArea
                    if case .idle = intelligence.phase {
                        suggestionChips
                    }
                }
                .padding()
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            inputBar
        }
    }

    @ViewBuilder private var answerArea: some View {
        switch intelligence.phase {
        case .idle:
            VStack(alignment: .leading, spacing: 8) {
                Image(systemName: "sparkles")
                    .font(.title)
                    .foregroundStyle(Color.brand)
                Text("Ask me anything about the countries you've visited — on-device, private to you.")
                    .foregroundStyle(.secondary)
            }

        case .thinking:
            HStack(spacing: 10) {
                ProgressView()
                Text("Thinking…")
                    .foregroundStyle(.secondary)
            }

        case .answered(let text):
            answerBubble(text)

        case .failed(let message):
            Label(message, systemImage: "exclamationmark.triangle")
                .foregroundStyle(.orange)
        }
    }

    private func answerBubble(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "globe.europe.africa.fill")
                .foregroundStyle(Color.brand)
                .padding(.top, 2)
            Text(text)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding()
        .background(Color.brand.opacity(0.08), in: RoundedRectangle(cornerRadius: 14))
    }

    private var suggestionChips: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Try asking")
                .font(.caption)
                .foregroundStyle(.secondary)
            ForEach(TravelIntelligence.suggestions, id: \.self) { suggestion in
                Button {
                    submit(suggestion)
                } label: {
                    Text(suggestion)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 10)
                        .background(Color.brand.opacity(0.10), in: Capsule())
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var inputBar: some View {
        HStack(spacing: 8) {
            TextField("Ask about your travels…", text: $question, axis: .vertical)
                .lineLimit(1...4)
                .textFieldStyle(.plain)
                .focused($fieldFocused)
                .onSubmit { submit(question) }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(.quaternary.opacity(0.5), in: Capsule())

            Button {
                submit(question)
            } label: {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.system(size: 30))
                    .foregroundStyle(canSend ? Color.brand : Color.secondary)
            }
            .buttonStyle(.plain)
            .disabled(!canSend)
        }
        .padding()
        .background(.bar)
    }

    private var canSend: Bool {
        guard case .thinking = intelligence.phase else {
            return !question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        return false
    }

    private func submit(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        question = ""
        fieldFocused = false
        Task { await intelligence.ask(trimmed) }
    }

    // MARK: - Unavailable

    @ViewBuilder private var unavailableView: some View {
        switch intelligence.availability {
        case .unavailable(.appleIntelligenceNotEnabled):
            ContentUnavailableView(
                "Apple Intelligence is Off",
                systemImage: "sparkles",
                description: Text("Turn on Apple Intelligence in Settings to ask about your travels.")
            )
        case .unavailable(.modelNotReady):
            ContentUnavailableView(
                "Getting Ready",
                systemImage: "arrow.down.circle",
                description: Text("The on-device model is still downloading. Try again in a little while.")
            )
        default:
            ContentUnavailableView(
                "Not Available",
                systemImage: "exclamationmark.triangle",
                description: Text("This device can't run the on-device travel assistant.")
            )
        }
    }
}
