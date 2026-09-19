import SwiftUI

/// What a grounded meal says about itself (#594).
///
/// ### Why a chip and a list, and not one or the other
///
/// The chip answers "is this a lookup or a guess", which is the question the
/// number's precision raises the moment it stops being a round 10. The list
/// answers "whose figures", which is the only way the claim can be checked, and
/// a provenance claim nobody can check is a claim worth nothing. The chip goes
/// everywhere a meal appears; the list goes where there is room to read it.
///
/// ### Why it does not say "exact"
///
/// A published panel is a fact and the portion scaled from it is still the
/// model's assumption, so the meal is part looked-up and part estimated. The
/// confidence band stays beside this and keeps reporting the portion, which is
/// where a text-derived estimate actually goes wrong.
enum MealGrounding {

    /// The words on the chip. One string, so the preview, the row and the
    /// detail sheet cannot describe the same meal three ways.
    ///
    /// One word, because the chip sits in a row of chips and "Published
    /// nutrition" wrapped to two lines wherever that row was tight, setting the
    /// whole row a line taller for a label whose second word carries nothing.
    /// What it is published nutrition FOR is the meal the chip is sitting on.
    static let chipLabel = "Published"

    /// The chip itself, in the same shape every other meal flag uses.
    static func chip() -> MealFlagChip {
        MealFlagChip(chipLabel, systemImage: "checkmark.seal", tint: Tokens.success)
    }

    /// How the numbers on a meal should be printed, given where they came from.
    ///
    /// The ONE place this is decided. A surface that worked it out for itself is
    /// how one screen rounds a published figure and the next one does not.
    /// `isFromLibrary` is the third way a figure can be stated rather than
    /// guessed (#625). A meal logged entirely out of the saved item library is
    /// the MOST exact kind there is: every number was read off a packet and
    /// scaled by a ratio, and no portion was assumed anywhere. Rounding 186 to
    /// 190 on that row throws away the exactness the library exists to give.
    ///
    /// It is deliberately true only for a meal whose SOURCE is the library. A
    /// meal that mixed a typed description with a picked item has an estimated
    /// half, so its total really is a guess and `.estimate` is the honest way
    /// to print it.
    static func precision(
        isGrounded: Bool,
        totalsWereOverridden: Bool = false,
        isFromLibrary: Bool = false
    ) -> MealFormat.Precision {
        (isGrounded || totalsWereOverridden || isFromLibrary) ? .stated : .estimate
    }
}

/// The pages a grounded estimate was built from, listed so the figure can be
/// checked (#594).
///
/// Tapping a source opens it. That is the whole point: the app is asserting
/// that a number came from somewhere, and the assertion is only worth making if
/// the somewhere is one tap away.
struct MealSourcesBlock: View {
    let sources: [WebSearchSource]

    var body: some View {
        if sources.isEmpty {
            EmptyView()
        } else {
            VStack(alignment: .leading, spacing: Space.xs) {
                Text("Sources").eyebrow()
                ForEach(sources, id: \.url) { source in
                    if let url = URL(string: source.url) {
                        Link(destination: url) {
                            Label(source.title, systemImage: "arrow.up.right.square")
                                .font(.edFootnote)
                                .foregroundStyle(Tokens.accentMeals)
                                .multilineTextAlignment(.leading)
                                .fixedSize(horizontal: false, vertical: true)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .buttonStyle(.plain)
                    } else {
                        // A source whose URL will not parse is still evidence of
                        // where the figure came from, so it is shown rather than
                        // dropped. It just cannot be opened.
                        Text(source.title)
                            .font(.edFootnote)
                            .foregroundStyle(Tokens.muted)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
    }
}
