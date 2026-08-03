import Foundation

/// What a wallet-style document is attached to (#432).
///
/// The attachment stack — one picker for an image, a PDF or a `.pkpass`, a read
/// that fills in what the file does not print, duplicate detection, enrich-in-place,
/// and a rule deciding what earns a Wallet card — was built for tasks across #399
/// → #420. A trip stop needs every part of it and none of it differently: a
/// boarding pass turns up the day before the flight, a rental voucher the morning
/// you collect the car, and both arrive after the stop they belong to already
/// exists.
///
/// So the owner became a value rather than the pipeline being copied. Everything
/// downstream of this type is written once and asked which kind it is only where
/// the two genuinely differ: the copy shown to a person, and the accent the cards
/// are drawn in.
///
/// ## Why the stored model is still called `LocalTaskTicket`
///
/// It now holds documents for both, so its name undersells it. It keeps the name
/// anyway: a `@Model` class name IS the entity name in the store, so renaming it
/// makes an existing install open a schema with an entity it has never heard of.
/// The name is cosmetic and the migration is not.
enum TicketOwner: Hashable, Sendable {
    /// A task, by `LocalTodo.clientUUID` (#399).
    case task(UUID)
    /// A stop on a trip's timeline, by `LocalItineraryItem.clientUUID` (#432).
    case tripStop(UUID)

    /// The owning record's `clientUUID`. Stored on `LocalTaskTicket.todoClientUUID`
    /// whichever kind it is, so "which record owns this" is one column and one
    /// index rather than two half-populated ones.
    var id: UUID {
        switch self {
        case .task(let id), .tripStop(let id): return id
        }
    }

    /// Stored on `LocalTaskTicket.itineraryItemUUID`, which is the only thing that
    /// tells the two kinds apart on the way back out. `nil` for a task, which is
    /// what every row written before this existed decodes to — so an old row is
    /// correctly a task's without a migration.
    var itineraryItemUUID: UUID? {
        switch self {
        case .task:               return nil
        case .tripStop(let id):   return id
        }
    }

    /// What the owner is called in copy the person reads ("the task itself stays").
    var noun: String {
        switch self {
        case .task:     return "task"
        case .tripStop: return "stop"
        }
    }

    /// The section whose accent the attachment UI draws in, so a document on a trip
    /// stop reads as part of the trip rather than as a task that wandered in.
    var section: AppSection {
        switch self {
        case .task:     return .tasks
        case .tripStop: return .itineraries
        }
    }

    /// This owner as the may-not-exist-yet shape the editor UI takes.
    var ref: TicketOwnerRef {
        switch self {
        case .task(let id):     return .task(id)
        case .tripStop(let id): return .tripStop(id)
        }
    }
}

/// An owner that may not exist yet, which is the state an editor composing a new
/// record is in (#432).
///
/// A document can be added while composing, and is held unwritten until the record
/// is committed — an editor that created the record the moment a file arrived would
/// leave one behind when Cancel is pressed. The kind is known from the start even
/// when the id is not, which is what lets the copy and the accent be right before
/// anything is saved.
struct TicketOwnerRef: Hashable, Sendable {
    enum Kind: Hashable, Sendable {
        case task
        case tripStop
    }

    let kind: Kind
    /// `nil` while the owning record is still unsaved.
    let id: UUID?

    init(kind: Kind, id: UUID?) {
        self.kind = kind
        self.id = id
    }

    static func task(_ id: UUID?) -> TicketOwnerRef { .init(kind: .task, id: id) }
    static func tripStop(_ id: UUID?) -> TicketOwnerRef { .init(kind: .tripStop, id: id) }

    /// The resolved owner, or `nil` while the record it belongs to is unsaved.
    var owner: TicketOwner? {
        guard let id else { return nil }
        switch kind {
        case .task:     return .task(id)
        case .tripStop: return .tripStop(id)
        }
    }

    /// A stand-in owner for a document read against a record that does not exist
    /// yet, carrying the right KIND and a throwaway id.
    ///
    /// The kind is what matters: a held document is rendered as a real card before
    /// anything is written, and the card takes its accent from what it hangs off.
    /// Without this a boarding pass added while composing a stop would draw in the
    /// Tasks indigo until the moment it was saved. The id is replaced when the
    /// document is flushed, which is why a random one is safe here.
    var unsavedPlaceholder: TicketOwner {
        switch kind {
        case .task:     return .task(UUID())
        case .tripStop: return .tripStop(UUID())
        }
    }

    /// Copy and colour are needed before there is an id, so both read off the kind.
    var noun: String {
        switch kind {
        case .task:     return "task"
        case .tripStop: return "stop"
        }
    }

    var section: AppSection {
        switch kind {
        case .task:     return .tasks
        case .tripStop: return .itineraries
        }
    }
}
