import Foundation

/// One thing to name: a stored row and the words that describe it (#603).
struct MealNamingRequest: Sendable, Equatable {
    /// The row's `clientUUID`. Sent to the model and read back, so a name
    /// cannot land on the wrong row when the answer comes back reordered.
    let id: String

    /// What the user typed: a meal's description, or a planned block's title.
    let text: String
}

extension AnthropicClient {

    /// Name meals that are already stored, in ONE call (#603).
    ///
    /// ### Why this exists at all
    ///
    /// The estimate names a meal as it is made, in the same call that produces
    /// its numbers, so nothing logged from now on needs this. What it cannot do
    /// is reach backwards: every meal logged before the field existed, every
    /// plan block typed and never estimated, and any answer that arrives without
    /// a name. Those rows fall through to `MealDisplayName`'s truncation, which
    /// is a floor and not an answer — it cuts "two eggs on toast with butter
    /// and…" exactly where the sentence stops saying what the meal was.
    ///
    /// ### Why one call and not one per meal
    ///
    /// Naming is the cheapest thing a model can be asked to do and the batch is
    /// what keeps it cheap: forty descriptions in, forty names out, one request.
    /// A call per row would be forty round trips to fix a display problem, which
    /// is a bill nobody agreed to.
    ///
    /// ### Why the ids go out and come back
    ///
    /// The reply is matched by id, never by position. A model that drops one
    /// entry or returns them in another order would otherwise put the dinner's
    /// name on the breakfast, and a wrong name is worse than a truncated one:
    /// the truncation is visibly a stub, the wrong name reads as a fact.
    ///
    /// Partial answers are fine and expected. Anything unnamed stays unnamed and
    /// is offered again on the next pass.
    ///
    /// - Returns: `id → name`, holding only the entries the model answered and
    ///   only where the name is non-empty and not a copy of the input.
    func nameMeals(_ requests: [MealNamingRequest]) async throws -> [String: String] {
        guard !requests.isEmpty else { return [:] }
        guard let key = AppConfig.anthropicAPIKey, !key.isEmpty else {
            throw MealEstimationError.notConfigured
        }

        let prompt = Self.mealNamingPrompt(requests)

        let body: AnthropicJSONValue = .object([
            "model": .string(Self.model),
            // Names are short and there are at most forty of them. Generous
            // enough for the thinking block this model returns, which spends
            // the same budget the answer needs (#543).
            "max_tokens": .int(4096),
            "messages": .array([
                .object([
                    "role": .string("user"),
                    "content": .array([
                        .object(["type": .string("text"), "text": .string(prompt)])
                    ])
                ])
            ])
        ])

        var request = URLRequest(url: Self.endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(key, forHTTPHeaderField: "x-api-key")
        request.setValue(Self.anthropicVersion, forHTTPHeaderField: "anthropic-version")
        // No tools and no search, so this is a plain generation. It runs in the
        // background behind a screen the user is already reading, so it is
        // allowed to take its time and must never be the reason a tab is slow.
        request.timeoutInterval = 60

        do {
            request.httpBody = try Self.encoder.encode(body)
        } catch {
            throw MealEstimationError.parse(error)
        }

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw MealEstimationError.transport(error)
        }

        guard let http = response as? HTTPURLResponse else {
            throw MealEstimationError.http(0, "non-HTTP response")
        }
        guard (200..<300).contains(http.statusCode) else {
            let preview = String(data: data.prefix(800), encoding: .utf8) ?? "<non-utf8 bytes>"
            throw MealEstimationError.http(http.statusCode, preview)
        }

        guard let root = (try? Self.decoder.decode(AnthropicJSONValue.self, from: data))?.objectValue else {
            throw MealEstimationError.noJSON
        }
        let text = (root["content"]?.arrayValue ?? []).compactMap { block -> String? in
            guard let fields = block.objectValue,
                  fields["type"]?.stringValue == "text" else { return nil }
            return fields["text"]?.stringValue
        }.joined(separator: "\n")

        guard let jsonString = Self.firstJSONBlock(in: text),
              let jsonData = jsonString.data(using: .utf8),
              let decoded = (try? Self.decoder.decode(AnthropicJSONValue.self, from: jsonData))?.objectValue else {
            if root["stop_reason"]?.stringValue == "max_tokens" { throw MealEstimationError.truncated }
            throw MealEstimationError.noJSON
        }

        return Self.names(from: decoded["names"]?.arrayValue ?? [], asked: requests)
    }

    /// Read the reply into `id → name`, dropping everything that cannot be used.
    ///
    /// Four things are thrown away rather than stored: an id nobody asked about,
    /// an empty name, a name identical to the text it was made from (which
    /// stores a sentence in the field that exists to avoid one), and a name long
    /// enough that it would be truncated anyway.
    static func names(
        from raw: [AnthropicJSONValue],
        asked: [MealNamingRequest]
    ) -> [String: String] {
        let texts = Dictionary(asked.map { ($0.id, $0.text) }, uniquingKeysWith: { first, _ in first })
        var out: [String: String] = [:]

        for entry in raw {
            guard let fields = entry.objectValue,
                  let id = fields["id"]?.stringValue,
                  let source = texts[id] else { continue }

            let name = (fields["title"]?.stringValue ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .trimmingCharacters(in: CharacterSet(charactersIn: ".;,"))
            guard !name.isEmpty else { continue }
            guard name.caseInsensitiveCompare(source) != .orderedSame else { continue }
            // A name over the display cap would be shortened on every surface it
            // reaches, which is the truncation this whole field exists to avoid.
            guard name.count <= MealDisplayName.characterCap else { continue }

            out[id] = name
        }
        return out
    }

    // MARK: - Prompt

    /// The naming prompt.
    ///
    /// The rule is `MealToolSchema.titleRule` verbatim, which is the same string
    /// the composer's prompt, both meal tools and the plan tool carry. A second
    /// statement of it here is exactly the drift `MealToolSchema` exists to
    /// prevent: a name typed by this path and a name typed by the estimate have
    /// to be the same kind of thing, or a list would read in two voices.
    static func mealNamingPrompt(_ requests: [MealNamingRequest]) -> String {
        let lines = requests.map { request in
            // The text is JSON-escaped, so a description carrying a quote or a
            // newline cannot break the block the model is reading.
            let escaped = request.text
                .replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "\"", with: "\\\"")
                .replacingOccurrences(of: "\n", with: " ")
            return "  {\"id\": \"\(request.id)\", \"text\": \"\(escaped)\"}"
        }.joined(separator: ",\n")

        return """
        Name each of these meals. Each one is what a user typed about something \
        they ate or plan to eat, in their own words. The app shows your name in a \
        LIST and keeps their own words behind it.

        The meals:
        [
        \(lines)
        ]

        Return STRICT JSON inside a ```json fence and nothing else — no prose \
        before or after:

        {
          "names": [
            {"id": "the id you were given, copied exactly", "title": "Eggs on toast and a flat white"}
          ]
        }

        Rules:
        \(MealToolSchema.titleRule)
        - One entry per meal you were given, carrying that meal's id EXACTLY as \
        it was written. Never invent an id and never reorder your answer to match \
        anything.
        - Name what the words say. Do not guess at a dish the text does not name: \
        "something from the canteen" is "Canteen food", not "Chicken rice".
        - If the text is already a short dish name, return it unchanged.
        """
    }
}
