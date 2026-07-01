import Foundation

/// Converts a transcript rendered in Urdu (Perso-Arabic) script into Hindi
/// (Devanagari), while leaving English / already-Devanagari text untouched
/// (issue #151).
///
/// Hindi and Urdu are the same spoken language (Hindustani); OpenAI's STT
/// auto-detect frequently renders spoken Hindi in Urdu script. The voice
/// preview should only ever show Hindi or English, never Urdu, so we run this
/// normalization on the finalized transcript.
///
/// The Claude round-trip fires ONLY when Perso-Arabic characters are present,
/// so English and Devanagari transcripts incur no latency or token cost. On any
/// failure the original text is returned — a visible (Urdu) preview beats an
/// empty one, and the downstream parse still translates it to English.
enum HindiScriptNormalizer {

    /// True if `text` contains any Perso-Arabic (Urdu) script. Exposed so
    /// callers (e.g. the voice overlay) can cheaply decide whether a
    /// normalization is pending without re-scanning private state.
    static func containsPersoArabic(_ text: String) -> Bool {
        text.unicodeScalars.contains { s in
            (0x0600...0x06FF).contains(s.value)   // Arabic
                || (0x0750...0x077F).contains(s.value)   // Arabic Supplement
                || (0x08A0...0x08FF).contains(s.value)   // Arabic Extended-A
                || (0xFB50...0xFDFF).contains(s.value)   // Arabic Presentation Forms-A
                || (0xFE70...0xFEFF).contains(s.value)   // Arabic Presentation Forms-B
        }
    }

    /// If `text` is in Urdu script, convert it to Hindi in Devanagari via
    /// Claude; otherwise return it unchanged (no API call). Never throws —
    /// returns the input on any error so the voice pipeline degrades to showing
    /// the raw transcript rather than nothing.
    static func normalize(_ text: String) async -> String {
        guard containsPersoArabic(text) else { return text }

        let system = """
        You convert Hindi text written in Urdu (Perso-Arabic) script into Hindi \
        written in Devanagari script. Hindi and Urdu are the same spoken \
        language, so this is a script conversion. Output ONLY the Devanagari \
        version of the input text, preserving the meaning, numbers, and any \
        proper nouns. Do not translate to English, do not add quotes, notes, or \
        any other text.
        """

        do {
            let response = try await AnthropicClient().send(
                systemPrompt: system,
                messages: [AnthropicMessage(role: "user", content: [.text(text)])],
                tools: []
            )
            let converted = response.content
                .compactMap { block -> String? in
                    if case .text(let t) = block { return t }
                    return nil
                }
                .joined()
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return converted.isEmpty ? text : converted
        } catch {
            NSLog("[voice] script normalize failed, keeping raw transcript")
            return text
        }
    }
}
