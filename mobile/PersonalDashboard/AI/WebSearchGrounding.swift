import Foundation

/// One page a server-side web search actually returned (#594).
///
/// Read out of the response's own `web_search_tool_result` blocks, never out of
/// prose the model wrote about what it looked at. A model asked to list its
/// sources will list plausible ones, so a citation taken from the answer says
/// nothing about whether a search happened.
struct WebSearchSource: Codable, Equatable, Hashable, Sendable {
    /// The page title the search returned. Falls back to the URL when the
    /// result carries no title, so a source is never a blank line.
    let title: String

    /// The page the figure can be checked against. This is the whole point of
    /// storing a source at all.
    let url: String

    init(title: String, url: String) {
        self.title = title
        self.url = url
    }
}

/// Everything this app decides about Anthropic's server-side web search, all of
/// it decided FROM THE RESPONSE (#594).
///
/// ### Why there is no "did you search" field
///
/// The obvious shape is to ask the model to report whether it looked the
/// product up, and it is the wrong one for the same reason `MealEstimateGuards`
/// exists: a guard the model grades itself against is not a guard. A model that
/// answered from memory and believed it had searched would set the flag, and the
/// figure would carry a provenance badge it never earned. The presence of a
/// `web_search_tool_result` block is a fact about the wire, so it cannot be
/// wrong about itself.
///
/// ### Why the failure shape needs its own branch
///
/// A server tool that fails comes back on an HTTP 200 with an error object in
/// place of the result list, so nothing upstream catches it: the request
/// succeeded. `sources(inResultBlock:)` therefore asks which of the two shapes
/// arrived before it reads anything, and answers with no sources rather than
/// throwing. A failed search must cost the meal its badge, never the meal.
enum WebSearchGrounding {

    /// The server tool's own type string. `claude-sonnet-5` supports this
    /// variant with no beta header, and `anthropic-version` stays at
    /// 2023-06-01.
    ///
    /// ### Why the BASIC variant and not `web_search_20260209`
    ///
    /// The newer variant adds dynamic filtering, which it implements by running
    /// code execution under the hood, and that code execution is the entire
    /// cost. Measured against the live API on one branded lookup, same model,
    /// same prompt, same `max_uses`:
    ///
    ///   `web_search_20260209`: 26.6 s and 60.9 s, with 3 and 6 code-execution
    ///   blocks in the response.
    ///   `web_search_20250305`: 6.5 s, 8.9 s, 5.8 s, with zero.
    ///
    /// Both found the product. The filtering is built for research that has to
    /// sift many pages; this asks one question with one right answer, so it pays
    /// the whole cost and collects none of the benefit. On a surface whose
    /// entire design is one field and one button, a 30-to-60 second wait is not
    /// a slower feature, it is a different and worse one, and the newer variant
    /// was also blowing through a 150 s ceiling often enough to lose meals.
    ///
    /// Reverting to `_20260209` means re-measuring this, not just changing the
    /// string. The result block type is `web_search_tool_result` on both, so
    /// nothing downstream of here can tell you which one is in use.
    static let toolType = "web_search_20250305"

    /// The name the tool is advertised under, and the name its blocks come
    /// back under.
    static let toolName = "web_search"

    /// How many searches the server may run inside one turn.
    ///
    /// Small on purpose. Web search is billed per search on top of tokens, and
    /// one branded meal is one product: a couple of attempts is room to retry a
    /// phrasing, not a research budget.
    ///
    /// Lowered from 3 to 2 in #594. Live branded lookups settle in one or two
    /// searches, and the third was spent widening an answer the first two had
    /// already found: it returned more pages about the same bowl, not a better
    /// figure for it. Each search is a round trip plus the pages behind it, so
    /// the one that adds nothing is pure wait and pure cost.
    static let maxUses = 2

    /// How many times a paused turn may be resumed before the app gives up on
    /// it and works with what it has.
    ///
    /// A pause is the server saying the turn is incomplete, so the resume is
    /// not optional if the answer is to arrive at all. The cap is what stops a
    /// pathological turn from looping: two resumes is three round trips for one
    /// estimate, which is already more than any meal should need.
    static let maxResumes = 2

    /// How many sources a grounded meal keeps.
    ///
    /// Three searches return far more pages than three: the live branded call
    /// came back with 22 distinct URLs. Every one of them would otherwise be
    /// stored on the row, drawn under the meal, written to the archive and
    /// re-broadcast on the next sync pass, to say something four of them
    /// already say.
    ///
    /// Six is the number the UI can show without becoming a bibliography, and
    /// it is enough for the user's actual question on seeing "Published
    /// nutrition", which is "whose, and can I open it". It is `maxUses` searches
    /// times `maxPerSearch`, with a spare row: the ceiling should never be what
    /// decides a normal two-product meal, only what stops a pathological one.
    static let maxStoredSources = 6

    /// How many sources one search may contribute.
    ///
    /// Two, so a meal naming two products keeps evidence for both. This is the
    /// number that actually protects the second product; `maxStoredSources` is
    /// only a backstop.
    ///
    /// Two rather than one because the top hit for a packaged product is often
    /// a retail listing rather than a nutrition panel (the SuperYou search
    /// returned an Amazon page first), and a second row usually carries the
    /// figures.
    static let maxPerSearch = 2

    /// The content-block type that carries a completed search.
    static let resultBlockType = "web_search_tool_result"

    /// The content-block type that carries the search the SERVER ran. It looks
    /// like a `tool_use` block and is not one: nothing on the device executes
    /// it, and anything that dispatches on client tool calls must skip it.
    static let serverToolUseBlockType = "server_tool_use"

    /// `stop_reason` for a turn the server paused mid-way. The turn is
    /// incomplete, not finished and not truncated, and the only correct
    /// response is to send it back and ask for the rest.
    static let pauseStopReason = "pause_turn"

    /// The tool exactly as a request's `tools` array carries it.
    ///
    /// A server tool is declared by TYPE, so it has no description and no
    /// `input_schema`: the schema lives on Anthropic's side. Sending the three
    /// keys a client tool carries is rejected.
    static var toolJSON: AnthropicJSONValue {
        .object([
            "type": .string(toolType),
            "name": .string(toolName),
            "max_uses": .int(maxUses)
        ])
    }

    // MARK: - Reading the response

    /// The sources one `web_search_tool_result` block returned, or none.
    ///
    /// `content` is a LIST of `web_search_result` on success and an OBJECT such
    /// as `{"error_code": "max_uses_exceeded"}` on failure. Both arrive under
    /// the same key on the same HTTP 200, so the shape is asked about before it
    /// is read. A block of any other type answers with no sources, which is what
    /// lets a caller hand this whole content array in without pre-filtering it.
    static func sources(inResultBlock block: AnthropicJSONValue) -> [WebSearchSource] {
        guard let fields = block.objectValue,
              fields["type"]?.stringValue == resultBlockType,
              let results = fields["content"]?.arrayValue else { return [] }

        return results.compactMap { entry -> WebSearchSource? in
            guard let result = entry.objectValue,
                  let url = result["url"]?.stringValue?
                      .trimmingCharacters(in: .whitespacesAndNewlines),
                  !url.isEmpty else { return nil }
            let title = result["title"]?.stringValue?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return WebSearchSource(title: title.isEmpty ? url : title, url: url)
        }
    }

    /// Every source a whole response's content array is grounded in.
    ///
    /// Empty means the estimate was NOT grounded, whatever the prose says. A
    /// turn that searched and found nothing, and a turn whose search failed,
    /// both land here as empty, and both are correct: neither produced a
    /// published figure to point at.
    ///
    /// Duplicates are dropped on the URL and the first occurrence wins, because
    /// one product page answers several queries and a list that repeats it
    /// reads as several independent sources.
    ///
    /// Capped at `maxStoredSources`. The cap is not tidiness: a live call for
    /// "Guzman y Gomez chicken burrito bowl" returned 22 distinct pages across
    /// its three searches, and all 22 were being kept. That is a list nobody
    /// reads, rendered under every grounded meal, carried in the row's blob,
    /// written into the archive and broadcast on the next sync pass. A stub
    /// returns two sources and can never show this, which is why the number
    /// comes from the live run and not from the tests.
    ///
    /// The quota is PER SEARCH, not first-come across the whole response, and
    /// that distinction is the whole correctness of this function.
    ///
    /// One meal can name two products: "zero-cal 100PLUS + SuperYou protein
    /// wafer" runs one search for each. The results arrive in query order, so a
    /// flat first-N cap spent every slot on the drink and threw away every page
    /// for the wafer. The meal then showed four sources, all of them about the
    /// thing the user was least interested in, while the assumptions line talked
    /// about a product with no source behind it. Nothing looked broken: a
    /// grounded meal with four real citations is exactly what success looks
    /// like. Taking a slice per block means every product that was searched
    /// keeps its own evidence.
    ///
    /// Within one search the first few win, because results arrive ranked. This
    /// is a provenance list the user can open, not an audit log of every page
    /// fetched: the tail of a single query is near-duplicates and drift (that
    /// 100PLUS search returned pages for Sprite Zero and an unrelated energy
    /// drink at positions 7 and 10).
    static func sources(inContent content: [AnthropicJSONValue]) -> [WebSearchSource] {
        var seen = Set<String>()
        var out: [WebSearchSource] = []
        for block in content {
            var keptFromThisSearch = 0
            for source in sources(inResultBlock: block) {
                guard keptFromThisSearch < maxPerSearch else { break }
                guard seen.insert(source.url).inserted else { continue }
                out.append(source)
                keptFromThisSearch += 1
                if out.count == maxStoredSources { return out }
            }
        }
        return out
    }

    /// Should this turn be sent back to be finished?
    ///
    /// Only a pause, and only while resumes remain. A `max_tokens` stop is a
    /// different failure with a different answer (`MealEstimationError.truncated`),
    /// and treating the two alike would report a paused turn as a malformed one.
    static func shouldResume(stopReason: String?, resumesUsed: Int) -> Bool {
        stopReason == pauseStopReason && resumesUsed < maxResumes
    }
}
