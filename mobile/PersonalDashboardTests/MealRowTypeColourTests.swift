import XCTest
import SwiftUI
import UIKit
@testable import PersonalDashboard

/// The meal type on the row, and the colour that carries it (#570).
///
/// The type moved from a grey eyebrow on line 2 to a coloured one on line 1,
/// so a day can be scanned by meal. Almost every rule that makes the choice
/// safe is invisible to a build and to a screenshot of one healthy day, so the
/// rules are pinned here:
///
/// 1. The four are distinct, in BOTH themes. A pair that separates on cream and
///    collapses on near-black is a palette that works half the time.
/// 2. None of them is amber, green, red or cyan. Hue on this surface means a
///    verdict about a quantity, and an identity painted in a verdict hue makes
///    one row assert two things in the same language.
/// 3. None of them is `accentMeals`, which is the deep-link pulse.
/// 4. A flagged row's gutter icon is still the warning tint. A flag outranks an
///    identity.
/// 5. The spoken row still names the meal type, for every one of the four.
/// 6. The row still holds at phone width with a long description, which now has
///    to share its first line with the type.
@MainActor
final class MealRowTypeColourTests: XCTestCase {

    private let day = Date(timeIntervalSince1970: 1_757_462_400)

    // MARK: - Resolving a token

    /// One resolved colour, as the renderer would draw it in a given theme.
    ///
    /// `Color.paper` is backed by a dynamic `UIColor`, so a token compared as a
    /// `Color` proves only that two `static let`s are different objects. Every
    /// assertion below reads the actual channels of the actual theme.
    private struct RGB {
        let r: CGFloat, g: CGFloat, b: CGFloat

        /// Degrees on the colour wheel. Meaningless at zero saturation, which
        /// is why every caller that uses it also has `saturation` to hand.
        var hue: CGFloat {
            let maxC = max(r, g, b), minC = min(r, g, b)
            let d = maxC - minC
            guard d > 0 else { return 0 }
            let h: CGFloat
            switch maxC {
            case r: h = ((g - b) / d).truncatingRemainder(dividingBy: 6)
            case g: h = (b - r) / d + 2
            default: h = (r - g) / d + 4
            }
            let deg = h * 60
            return deg < 0 ? deg + 360 : deg
        }

        var saturation: CGFloat {
            let maxC = max(r, g, b)
            guard maxC > 0 else { return 0 }
            return (maxC - min(r, g, b)) / maxC
        }

        /// Straight channel distance, in the 0...1 cube. A cheap stand-in for
        /// "these two are not the same swatch".
        func distance(to other: RGB) -> CGFloat {
            let dr = r - other.r, dg = g - other.g, db = b - other.b
            return (dr * dr + dg * dg + db * db).squareRoot()
        }
    }

    private func resolve(_ color: Color, _ style: UIUserInterfaceStyle) -> RGB {
        let resolved = UIColor(color).resolvedColor(with: UITraitCollection(userInterfaceStyle: style))
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        resolved.getRed(&r, green: &g, blue: &b, alpha: &a)
        return RGB(r: r, g: g, b: b)
    }

    private let themes: [(String, UIUserInterfaceStyle)] = [("light", .light), ("dark", .dark)]

    // MARK: - The four are four

    /// Every pair of meal types is told apart, in both themes.
    ///
    /// Separation is allowed to come from hue OR from chroma, and Snack is the
    /// reason. It is a cool slate sitting near Breakfast's indigo on the wheel
    /// and at about a quarter of its saturation, because a snack is the minor
    /// meal of a day and the quiet mark is the true one. A grey-blue and a
    /// vivid periwinkle are two different colours to a reader even though they
    /// are neighbours by degree.
    func testTheFourMealTypesAreDistinctInBothThemes() {
        for (name, style) in themes {
            for a in MealType.allCases {
                for b in MealType.allCases where b != a {
                    let x = resolve(a.tint, style)
                    let y = resolve(b.tint, style)
                    let hueGap = min(abs(x.hue - y.hue), 360 - abs(x.hue - y.hue))
                    let satGap = abs(x.saturation - y.saturation)
                    XCTAssertTrue(
                        hueGap >= 25 || satGap >= 0.25,
                        "\(a.displayName) and \(b.displayName) are \(hueGap)° and \(satGap) apart in \(name) mode"
                    )
                }
            }
        }
    }

    /// And no two of them are the same swatch, which is the weaker claim the
    /// one above would still pass if both halves of a pair were somehow nil.
    func testNoTwoMealTypesShareASwatch() {
        for (name, style) in themes {
            for a in MealType.allCases {
                for b in MealType.allCases where b != a {
                    XCTAssertGreaterThan(
                        resolve(a.tint, style).distance(to: resolve(b.tint, style)), 0.1,
                        "\(a.displayName) and \(b.displayName) are the same swatch in \(name) mode"
                    )
                }
            }
        }
    }

    // MARK: - Nothing from the verdict family

    /// The forbidden bands, by degree. Amber, green and red are the three
    /// `MealVerdict.tint` values; cyan belongs to the "Possible duplicate"
    /// chip. A meal type inside any of them would make the row say two
    /// different things in one language.
    func testNoMealTypeSitsInAVerdictHueBand() {
        let forbidden: [(String, ClosedRange<CGFloat>)] = [
            ("amber", 20...70),
            ("green", 90...170),
            ("cyan", 170...200),
        ]
        for (name, style) in themes {
            for type in MealType.allCases {
                let rgb = resolve(type.tint, style)
                for (family, band) in forbidden {
                    XCTAssertFalse(
                        band.contains(rgb.hue),
                        "\(type.displayName) is \(family) at \(rgb.hue)° in \(name) mode"
                    )
                }
                // Red wraps zero, so it is stated separately.
                XCTAssertFalse(
                    rgb.hue >= 340 || rgb.hue <= 20,
                    "\(type.displayName) is red at \(rgb.hue)° in \(name) mode"
                )
            }
        }
    }

    /// And none of them IS one of the reserved tokens, whatever band it landed
    /// in. Stated against the tokens themselves so a later edit to `warning` or
    /// to `accentMeals` that walked one of them onto a meal type fails here.
    func testNoMealTypeEqualsAReservedToken() {
        let reserved: [(String, Color)] = [
            ("under", MealVerdict.under.tint),
            ("on track", MealVerdict.onTrack.tint),
            ("over", MealVerdict.over.tint),
            ("info", Tokens.info),
            ("accentMeals", Tokens.accentMeals),
        ]
        for (name, style) in themes {
            for type in MealType.allCases {
                let rgb = resolve(type.tint, style)
                for (label, color) in reserved {
                    XCTAssertGreaterThan(
                        rgb.distance(to: resolve(color, style)), 0.15,
                        "\(type.displayName) is too close to \(label) in \(name) mode"
                    )
                }
            }
        }
    }

    /// Dinner is the one that gets near the red family, because it is the far
    /// end of the arc. In dark mode both it and `danger` are drawn light, which
    /// is exactly where a 30-degree gap would stop being enough. Pinned at 45.
    func testDinnerKeepsItsDistanceFromTheDangerHue() {
        for (name, style) in themes {
            let dinner = resolve(MealType.dinner.tint, style)
            let danger = resolve(Tokens.danger, style)
            let gap = min(abs(dinner.hue - danger.hue), 360 - abs(dinner.hue - danger.hue))
            XCTAssertGreaterThanOrEqual(gap, 45, "Dinner is \(gap)° from danger in \(name) mode")
        }
    }

    // MARK: - A flag outranks an identity

    /// A healthy row's gutter icon carries the meal type.
    func testAnUnflaggedRowDrawsItsGutterIconInTheMealTypeTint() {
        for type in MealType.allCases {
            let row = MealRow(meal: meal(type: type), isDuplicate: false, onTap: {})
            for (name, style) in themes {
                XCTAssertEqual(
                    resolve(row.gutterTint, style).distance(to: resolve(type.tint, style)), 0,
                    accuracy: 0.001,
                    "\(type.displayName)'s icon is not its own colour in \(name) mode"
                )
            }
        }
    }

    /// And a flagged one does not. All three flags take the icon, because all
    /// three are facts about the record and the record outranks the identity.
    func testAFlaggedRowDrawsItsGutterIconInTheWarningTint() {
        let flagged: [(String, MealRow)] = [
            ("suspect", MealRow(meal: meal(isSuspect: true), isDuplicate: false, onTap: {})),
            ("needs detail", MealRow(meal: meal(needsDetail: true), isDuplicate: false, onTap: {})),
            ("duplicate", MealRow(meal: meal(), isDuplicate: true, onTap: {})),
        ]
        for (label, row) in flagged {
            for (name, style) in themes {
                XCTAssertEqual(
                    resolve(row.gutterTint, style).distance(to: resolve(Tokens.warning, style)), 0,
                    accuracy: 0.001,
                    "a \(label) row's icon is not the warning tint in \(name) mode"
                )
            }
        }
    }

    // MARK: - VoiceOver

    /// The spoken row still opens with the meal type, for all four. The colour
    /// is the sighted half of this; the word is the whole of it for anyone
    /// listening.
    func testTheSpokenRowStillNamesEveryMealType() {
        for type in MealType.allCases {
            let text = MealRow(meal: meal(type: type), isDuplicate: false, onTap: {}).accessibilityText
            XCTAssertTrue(
                text.hasPrefix(type.displayName),
                "\(type.displayName) is missing from the spoken row: \(text)"
            )
        }
    }

    // MARK: - Phone width

    /// The type shares the first line with the description now, so the long
    /// description case has to be looked at again. The eyebrow is `fixedSize`
    /// — a truncated "LUNC…" would be worse than no word — so what gives is
    /// the description, which wraps under itself.
    func testTheRowStillHoldsAtPhoneWidthWithALongDescription() throws {
        let crowded = meal(
            "Leftover chicken biryani with raita, two papadums and a small gulab jamun from the fridge",
            type: .dinner,
            isSuspect: true,
            suspectReason: "The macros do not add up to the calories."
        )
        let renderer = ImageRenderer(
            content: MealRow(meal: crowded, isDuplicate: true, onTap: {}).frame(width: 390)
        )
        let image = try XCTUnwrap(renderer.uiImage)

        XCTAssertEqual(image.size.width, 390, accuracy: 0.5)
        XCTAssertGreaterThan(image.size.height, 120)
        XCTAssertLessThan(image.size.height, 400)
    }

    /// The whole eyebrow fits beside a description on one line at phone width,
    /// for the longest of the four words. "BREAKFAST" tracked and uppercased is
    /// the worst case, and if it ever stopped fitting the row would lose its
    /// first line to a single word.
    func testTheLongestMealTypeWordFitsTheColumn() throws {
        let column: CGFloat = 390 - (Space.lg * 2) - 22 - Space.md
        for type in MealType.allCases {
            let width = try XCTUnwrap(
                ImageRenderer(content: Text(type.displayName).eyebrow(type.tint)).uiImage?.size.width
            )
            XCTAssertLessThan(
                width, column / 2,
                "\(type.displayName) takes \(width) pt of a \(column) pt line and leaves no room for the description"
            )
        }
    }

    // MARK: - Fixtures

    private func meal(
        _ description: String = "Chicken rice",
        type: MealType = .lunch,
        needsDetail: Bool = false,
        isSuspect: Bool = false,
        suspectReason: String? = nil
    ) -> LocalMeal {
        LocalMeal(
            date: day,
            loggedAt: day,
            mealType: type.rawValue,
            mealDescription: description,
            calories: 600,
            proteinG: 35,
            carbsG: 70,
            fatG: 18,
            fibreG: 3,
            sugarG: 9,
            sodiumMg: 1_900,
            satFatG: 6,
            confidence: 0.6,
            source: MealSource.composer,
            needsDetail: needsDetail,
            isSuspect: isSuspect,
            suspectReason: suspectReason
        )
    }
}
