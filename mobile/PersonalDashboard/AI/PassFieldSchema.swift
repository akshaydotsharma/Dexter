import Foundation

/// The `other_fields` array shared by BOTH ticket extractors, and the parser that
/// reads it back (#522).
///
/// There are two extraction paths for what is, to the person holding it, one
/// object: `TaskTicketExtraction` reads a document attached to a task or a stop,
/// and `TicketExtraction` reads one filed straight into the Wallet or onto a
/// trip. They have drifted three times now — #475, #500, and again here, where a
/// membership card scanned into the Wallet lost its number and its expiry because
/// only the task-side schema had a generic label/value array to put them in.
///
/// Copying this block a second time would have set up the fourth. It is a single
/// definition instead, so a rule learned on one path cannot fail to reach the
/// other. The prose below is long on purpose: every paragraph in it is a rule the
/// model broke at least once (#481, #486, #487, #501).
enum PassFieldSchema {

    /// The JSON-schema value for the `other_fields` property. Callers add it under
    /// that key in their own tool definition.
    static let property: AnthropicJSONValue = .object([
        "type": .string("array"),
        "items": .object([
            "type": .string("object"),
            "properties": .object([
                "label_in_english": .object([
                    "type": .string("string"),
                    "description": .string("What this fact IS, in English, always. Translate the document's own word for it: Settore is Sector, Tribuna is Stand, Cancello is Gate, Ingresso is Entrance, Fila is Row, Posto is Seat, Piano is Floor. Two or three words at most.")
                ]),
                "value_as_printed": .object([
                    "type": .string("string"),
                    "description": .string("The fact itself, exactly as the document prints it, in the document's own language. Never translated: a place's name is a name, and renaming it sends someone to a sign that does not exist.")
                ])
            ]),
            "required": .array([.string("label_in_english"), .string("value_as_printed")])
        ]),
        "description": .string("The few remaining facts the HOLDER would act on that no field above covers, one entry per fact, each as \"Label: value\".\n\nEVERY LABEL IS IN ENGLISH. The label is yours to write, not the document's to dictate, so translate it whenever the ticket is in another language and keep the VALUE exactly as printed. \"Settore: 4\" is wrong and \"Sector: 4\" is right; likewise Tribuna to Stand, Cancello to Gate, Ingresso to Entrance, Porta to Door, Fila to Row, Posto to Seat, Piano to Floor, Anello to Tier. If you are writing a label that is not an English word, you have made a mistake.\n\nLEAVE OUT THE ISSUER'S BOOKKEEPING. A ticket is covered in numbers printed so the seller can reconcile, audit and reprint it, and none of them is a fact anyone acts on: fiscal, tax and VAT identification codes, internal or progressive sequence numbers, system identifiers, ticket-stock and card serial numbers, issue or printing timestamps, seal, authorisation and control codes, checksums and hashes, and category or genre codes that are bare numbers rather than words.\n\nLEAVE OUT THE EVENT'S PROGRAMME. A schedule printed on a ticket is the event's, not the holder's: session times, running order, support races, set times, undercard, opening hours, a list of what happens when. A race ticket printing thirteen practice and qualifying sessions has thirteen facts about the WEEKEND and none about this admission. Return none of them.\n\nLEAVE OUT WHAT THE BOOKING INCLUDES. A list whose values are all \"included\", \"yes\", a tick or the same word down the column is a list of terms of sale: insurance, breakdown cover, unlimited mileage, extras, protections. It says what was bought, not what happens on the day. What the person collects or presents IS a fact and stays: the car booked, the return time, the return place, the total paid.\n\nThe test is not whether it is printed, it is whether the holder would ever read it out, act on it, or need it to get in. Most tickets have NOTHING to return here, and an empty list is the right answer far more often than a long one. SIX is the most any document should need: if you are about to return more, you are keeping things that do not belong here, so cut back to the ones that matter. Good entries look like \"Ticket: In-Person\", \"Organiser: Vibe Coders SG\", \"Dress code: Smart casual\", \"Table: 12\", \"Entrance: Gate C from 18:00\", \"PIN code: 0226\", \"Phone: +39 328 918 9473\", \"Check-out: Monday 7 September, 00:00 - 11:00\". A number to CALL on the day — the host, the property, the desk, the driver — is one of the most useful things a card can carry, so keep it whenever one is printed. Do NOT repeat anything already returned in another field, in any language: if you returned a section, no entry here restates it under the document's own word for section. Do not include the barcode's contents, and do not invent labels: if the document shows a bare value with no label, omit it.\n\nLast check before you answer: read back every label you wrote. If any one of them is not an English word, rewrite it in English now. \"Settore\" is not an English word."),
    ])
}

extension PassFieldSchema {
    /// Decode `other_fields` into labelled fields (#420, reshaped in #487).
    ///
    /// Objects with named keys rather than `["Label: value", …]` strings. The flat
    /// string was the shape the model got right first time, but it left the one rule
    /// that keeps failing — write the label in English — as a sentence in a
    /// paragraph, read once. As an object the rule is the KEY's name,
    /// `label_in_english`, restated for every item the model emits. The Monza ticket
    /// came back "Sector" in three replays and "Settore" in the app on the same
    /// prompt; a field name is not something that drifts.
    ///
    /// Still accepts the old flat string, because rows written before this exist and
    /// a retry against a cached response should not silently drop every field.
    ///
    /// Everything from this route is placed `auxiliary`: a photograph shows one side
    /// of a document, so we know it was printed but not that it was on the back.
    static func parse(_ raw: AnthropicJSONValue?) -> [TicketMeta.PassField] {
        guard case let .array(items) = raw else { return [] }
        var out: [TicketMeta.PassField] = []
        for item in items {
            let label: String
            let value: String
            if let line = item.stringValue {
                guard let separator = line.firstIndex(of: ":") else { continue }
                label = String(line[line.startIndex..<separator])
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                value = String(line[line.index(after: separator)...])
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            } else if case let .object(pair) = item,
                      let l = pair["label_in_english"]?.stringValue,
                      let v = pair["value_as_printed"]?.stringValue {
                label = l.trimmingCharacters(in: .whitespacesAndNewlines)
                value = v.trimmingCharacters(in: .whitespacesAndNewlines)
            } else {
                continue
            }
            let field = TicketMeta.PassField(label: label, value: value, placement: .auxiliary)
            guard field.isRenderable else { continue }
            out.append(field)
        }
        return out
    }
}
