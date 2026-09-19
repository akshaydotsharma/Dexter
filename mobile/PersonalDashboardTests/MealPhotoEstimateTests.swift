import XCTest
@testable import PersonalDashboard

/// Estimating a meal from a photograph (#627).
///
/// Everything here is decidable without a live call. Whether `claude-sonnet-5`
/// correctly reads a plate of chicken rice is a property of the model and is
/// checked by using the app. Whether the app builds the right request, says the
/// right thing in the prompt, refuses the right empty inputs, and still writes a
/// meal that names something when the user typed nothing at all: that is all
/// arithmetic over bytes, and it is the half that regresses silently.
///
/// The prompt branches on two booleans — are there photos, is there text — and
/// the shape nobody would notice breaking is (photos, no text): the opening
/// sentence, the omitted description paragraph and the meal-type instruction all
/// change together there, and a prompt that announces a description and then
/// encloses none is the reliable way to make a model invent one.
@MainActor
final class MealPhotoEstimateTests: XCTestCase {

    private let noon = Date(timeIntervalSince1970: 1_726_740_000)

    // MARK: - The prompt

    /// Text and no photo: byte-for-byte the prompt this path built before #627.
    func testATypedMealMentionsNoPhotographAtAll() {
        let prompt = AnthropicClient.mealEstimationPrompt(
            description: "Two eggs on toast",
            photoCount: 0,
            mealTypeHint: nil,
            loggedAt: noon
        )

        XCTAssertTrue(prompt.contains("from its description"))
        XCTAssertTrue(prompt.contains("The description, verbatim:"))
        XCTAssertTrue(prompt.contains("Two eggs on toast"))
        XCTAssertFalse(
            prompt.contains("THE PHOTOGRAPH"),
            "a text-only estimate must not be told how to read an image it was never sent"
        )
        XCTAssertTrue(
            prompt.contains("Infer it from the description"),
            "the meal type is inferred from the evidence that exists"
        )
    }

    /// Photo and no text: no description paragraph, and nothing claiming there
    /// is one.
    func testAPhotoOnlyMealEnclosesNoDescriptionAndClaimsNone() {
        let prompt = AnthropicClient.mealEstimationPrompt(
            description: "",
            photoCount: 1,
            mealTypeHint: nil,
            loggedAt: noon
        )

        XCTAssertFalse(
            prompt.contains("The description, verbatim:"),
            "the prompt must not announce a description it does not enclose"
        )
        XCTAssertTrue(prompt.contains("from the attached photograph"))
        XCTAssertTrue(prompt.contains("The user typed nothing"))
        XCTAssertTrue(prompt.contains("THE PHOTOGRAPH"))
        XCTAssertTrue(
            prompt.contains("Infer it from what you can see"),
            "with no description, the meal type is inferred from the picture and the clock"
        )
    }

    /// Both: the precedence rule has to be in front of the model, because this
    /// is the only case where the two inputs can disagree.
    func testAPhotoWithTextCarriesBothAndSaysWhichWins() {
        let prompt = AnthropicClient.mealEstimationPrompt(
            description: "ate eight of these",
            photoCount: 2,
            mealTypeHint: nil,
            loggedAt: noon
        )

        XCTAssertTrue(prompt.contains("from the attached photographs"))
        XCTAssertTrue(prompt.contains("The description, verbatim:"))
        XCTAssertTrue(prompt.contains("ate eight of these"))
        XCTAssertTrue(prompt.contains("the description wins"))
        XCTAssertTrue(
            MealToolSchema.photoRule.contains("OUTRANKS"),
            "the rule the prompt points at is the one that states precedence"
        )
    }

    /// The plural is read by a human and it is wrong half the time if nobody
    /// checks it.
    func testTheOpeningCountsThePhotographs() {
        let one = AnthropicClient.mealEstimationPrompt(
            description: "", photoCount: 1, mealTypeHint: nil, loggedAt: noon
        )
        let two = AnthropicClient.mealEstimationPrompt(
            description: "", photoCount: 2, mealTypeHint: nil, loggedAt: noon
        )

        XCTAssertTrue(one.contains("the attached photograph."))
        XCTAssertTrue(two.contains("the attached photographs."))
    }

    /// A chosen meal type still wins over everything, photograph included.
    func testAChosenMealTypeStillOverridesThePicture() {
        let prompt = AnthropicClient.mealEstimationPrompt(
            description: "",
            photoCount: 1,
            mealTypeHint: .dinner,
            loggedAt: noon
        )

        XCTAssertTrue(prompt.contains("the user has already chosen \"dinner\""))
        XCTAssertFalse(prompt.contains("Infer it from"))
    }

    // MARK: - What counts as an input

    /// Neither a description nor a photo is still nothing, and it must fail
    /// before the request is built rather than as an API error.
    func testAnEmptyComposerIsStillRefused() async {
        UserAPIKeys.setAnthropic("sk-test-not-used")
        defer { UserAPIKeys.setAnthropic(nil) }

        do {
            _ = try await AnthropicClient().estimateMeal(description: "   ", photos: [])
            XCTFail("an empty description with no photo is not a meal")
        } catch let error as MealEstimationError {
            guard case .emptyDescription = error else {
                return XCTFail("expected .emptyDescription, got \(error)")
            }
            XCTAssertEqual(
                error.errorDescription,
                "Describe the meal, or add a photo of it.",
                "the message names both inputs, because both are now accepted"
            )
        } catch {
            XCTFail("expected MealEstimationError, got \(error)")
        }
    }

    // MARK: - The description a photographed meal is written with

    /// The photo is not kept (see `MealPhoto`), so a meal logged from one has to
    /// carry the model's reading of it in the one field search, the duplicate
    /// check and a later re-estimate all read.
    ///
    /// `libraryDescription` is what does that, and it is the same function the
    /// picked-items path uses — which is the point: one rule for turning items
    /// into a sentence, not two.
    func testAPhotographedMealIsDescribedByTheItemsTheModelRead() {
        let items = [
            MealItemEntry(
                name: "Chicken rice",
                portionQuantity: 320, portionUnit: "g",
                calories: 520, proteinG: 30, carbsG: 62, fatG: 16,
                fibreG: 2, sugarG: 3, sodiumMg: 900, satFatG: 4
            ),
            MealItemEntry(
                name: "Teh tarik",
                portionQuantity: 250, portionUnit: "ml",
                calories: 150, proteinG: 4, carbsG: 22, fatG: 5,
                fibreG: 0, sugarG: 20, sodiumMg: 60, satFatG: 3
            )
        ]

        let description = MealEstimationService.libraryDescription(for: items)

        XCTAssertEqual(description, "Chicken rice 320 g, Teh tarik 250 ml")
        XCTAssertFalse(
            description.isEmpty,
            "a row written from a photo must never carry an empty description"
        )
    }

    // MARK: - The bytes

    /// A `MealPhoto` states the one media type the Messages API is sent, and
    /// base64 of the bytes it holds. HEIC would be rejected by Anthropic rather
    /// than by anything here, which is the worst place to discover it.
    func testAPhotoIsAlwaysAnnouncedAsJPEG() {
        let photo = MealPhoto(jpegData: Data([0xFF, 0xD8, 0xFF, 0xE0]))

        XCTAssertEqual(photo.mediaType, "image/jpeg")
        XCTAssertEqual(photo.base64, Data([0xFF, 0xD8, 0xFF, 0xE0]).base64EncodedString())
    }
}
