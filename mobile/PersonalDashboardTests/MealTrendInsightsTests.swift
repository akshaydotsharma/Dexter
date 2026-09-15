import XCTest
@testable import PersonalDashboard

/// The Trends tab's arithmetic (#545).
///
/// Everything here runs against `MealInsights.build`, which is the ONE
/// computation behind both the collapsed band and the expanded panel. Testing
/// it is therefore testing both, and a number that passes here cannot appear
/// differently on the two halves of the card.
///
/// Detached `LocalMeal` values rather than a store: `build` reads properties and
/// writes nothing, and the day matching it does is `WallClock`'s, which is what
/// the day tests already cover.
@MainActor
final class MealTrendInsightsTests: XCTestCase {

    /// A fixed instant, so "the last 30 days" is the same 30 days on every run.
    private let now = Date(timeIntervalSince1970: 1_757_462_400)

    private var calendar: Calendar { .current }

    private var today: Date { calendar.startOfDay(for: now) }

    private func day(agoBy days: Int) -> Date {
        calendar.date(byAdding: .day, value: -days, to: today) ?? today
    }

    private func meal(
        daysAgo: Int,
        calories: Double = 2_000,
        protein: Double = 100,
        carbs: Double = 250,
        fat: Double = 70,
        fibre: Double = 30,
        sugar: Double = 40,
        sodium: Double = 2_000,
        satFat: Double = 20,
        type: MealType = .lunch,
        source: String = MealSource.composer,
        suspect: Bool = false,
        needsDetail: Bool = false
    ) -> LocalMeal {
        let local = day(agoBy: daysAgo)
        return LocalMeal(
            date: WallClock.dayAnchor(from: local),
            loggedAt: local,
            mealType: type.rawValue,
            mealDescription: "test meal",
            calories: calories,
            proteinG: protein,
            carbsG: carbs,
            fatG: fat,
            fibreG: fibre,
            sugarG: sugar,
            sodiumMg: sodium,
            satFatG: satFat,
            confidence: 0.6,
            source: source,
            needsDetail: needsDetail,
            isSuspect: suspect
        )
    }

    private func targets(
        calories: Double = 2_000,
        protein: Double = 100,
        carbs: Double = 250,
        fat: Double = 70,
        fibre: Double = 30,
        sugar: Double = 50,
        sodium: Double = 2_300,
        satFat: Double = 22
    ) -> MealTargets {
        MealTargets(
            calories: calories,
            proteinG: protein,
            carbsG: carbs,
            fatG: fat,
            fibreG: fibre,
            sugarG: sugar,
            sodiumMg: sodium,
            satFatG: satFat
        )
    }

    private func range(_ period: MealTrendPeriod) -> ClosedRange<Date> {
        MealTrendSelection(period: period).resolvedRange(now: now, calendar: calendar)
    }

    // MARK: - The bands

    /// The asymmetry is the whole feature. A floor at 130% is a good fortnight;
    /// a ceiling at 130% is the fact worth being told.
    func testFloorAt130PercentReadsOnTrackAndCeilingAt130PercentReadsOver() {
        XCTAssertEqual(Nutrient.protein.trendBand(value: 130, target: 100), .onTrack)
        XCTAssertEqual(Nutrient.fibre.trendBand(value: 39, target: 30), .onTrack)
        XCTAssertEqual(Nutrient.sodium.trendBand(value: 2_990, target: 2_300), .over)
        XCTAssertEqual(Nutrient.sugar.trendBand(value: 65, target: 50), .over)
    }

    /// Watch has to be a different word from Over, or the fourth band buys
    /// nothing.
    func testCeilingAt110PercentReadsWatchNotOver() {
        XCTAssertEqual(Nutrient.sodium.trendBand(value: 110, target: 100), .watch)
        XCTAssertEqual(Nutrient.saturatedFat.trendBand(value: 125, target: 100), .watch)
        XCTAssertEqual(Nutrient.saturatedFat.trendBand(value: 125.1, target: 100), .over)
        XCTAssertNotEqual(MealTrendBand.watch.label, MealTrendBand.over.label)
    }

    func testEveryBandBoundary() {
        // Floor: under below 85, on track to 150, over past it.
        XCTAssertEqual(Nutrient.protein.trendBand(value: 84.9, target: 100), .under)
        XCTAssertEqual(Nutrient.protein.trendBand(value: 85, target: 100), .onTrack)
        XCTAssertEqual(Nutrient.protein.trendBand(value: 150, target: 100), .onTrack)
        XCTAssertEqual(Nutrient.protein.trendBand(value: 150.1, target: 100), .over)

        // Ceiling: never under.
        XCTAssertEqual(Nutrient.sugar.trendBand(value: 0, target: 100), .onTrack)
        XCTAssertEqual(Nutrient.sugar.trendBand(value: 100, target: 100), .onTrack)
        XCTAssertEqual(Nutrient.sugar.trendBand(value: 100.1, target: 100), .watch)

        // Range: both sides are wrong.
        XCTAssertEqual(Nutrient.calories.trendBand(value: 89.9, target: 100), .under)
        XCTAssertEqual(Nutrient.calories.trendBand(value: 90, target: 100), .onTrack)
        XCTAssertEqual(Nutrient.calories.trendBand(value: 110, target: 100), .onTrack)
        XCTAssertEqual(Nutrient.calories.trendBand(value: 110.1, target: 100), .over)

        // No target is no verdict.
        XCTAssertNil(Nutrient.calories.trendBand(value: 2_000, target: 0))
    }

    // MARK: - Partial days

    /// The acceptance case, verbatim: 30 days, 24 logged, 2 partial, 4
    /// unlogged. The averages divide by 24 and the strip states all three.
    func testPartialDaysAreHeldOutOfAveragesAndCountedSeparately() {
        var meals: [LocalMeal] = []
        for offset in 0..<24 { meals.append(meal(daysAgo: offset, calories: 2_000)) }
        // Under half the 2,000 kcal target: under-LOGGED, not under-eaten.
        for offset in 24..<26 { meals.append(meal(daysAgo: offset, calories: 500)) }
        // 26...29 get nothing at all.

        let insights = MealInsights.build(
            meals: meals,
            targets: targets(),
            range: range(.last30),
            calendar: calendar
        )

        XCTAssertEqual(insights.health.totalDays, 30)
        XCTAssertEqual(insights.health.daysLogged, 24)
        XCTAssertEqual(insights.health.partialDays, 2)
        XCTAssertEqual(insights.health.unloggedDays, 4)
        XCTAssertEqual(insights.averageCalories, 2_000, accuracy: 0.001)
    }

    /// With the toggle on, the same 26 days divide the same total.
    func testIncludingPartialDaysChangesTheDivisor() {
        var meals: [LocalMeal] = []
        for offset in 0..<24 { meals.append(meal(daysAgo: offset, calories: 2_000)) }
        for offset in 24..<26 { meals.append(meal(daysAgo: offset, calories: 500)) }

        let included = MealInsights.build(
            meals: meals,
            targets: targets(),
            range: range(.last30),
            includePartialDays: true,
            calendar: calendar
        )

        XCTAssertEqual(included.averageCalories, (24 * 2_000 + 2 * 500) / 26, accuracy: 0.001)
        // The strip still reports the days as partial: including them changes
        // the divisor, not what they are.
        XCTAssertEqual(included.health.partialDays, 2)
    }

    /// A day whose every meal is held out has no numbers to stand on, whether
    /// or not a calorie target exists.
    func testDayOfOnlyExcludedMealsIsPartial() {
        let meals = [
            meal(daysAgo: 0, suspect: true),
            meal(daysAgo: 1, needsDetail: true),
            meal(daysAgo: 2)
        ]
        let insights = MealInsights.build(
            meals: meals,
            targets: nil,
            range: range(.last7),
            calendar: calendar
        )
        XCTAssertEqual(insights.health.daysLogged, 1)
        XCTAssertEqual(insights.health.partialDays, 2)
        XCTAssertEqual(insights.health.unloggedDays, 4)
    }

    // MARK: - Exclusions

    func testSuspectAndNeedsDetailMealsAreExcludedFromAveragesAndCountedInHealth() {
        let meals = [
            meal(daysAgo: 0, calories: 2_000),
            meal(daysAgo: 0, calories: 5_000, suspect: true),
            meal(daysAgo: 0, calories: 5_000, needsDetail: true),
            meal(daysAgo: 1, calories: 2_000, source: MealSource.user),
            meal(daysAgo: 2, calories: 2_000, source: MealSource.chat),
            meal(daysAgo: 3, calories: 2_000, source: MealSource.capture)
        ]

        let insights = MealInsights.build(
            meals: meals,
            targets: targets(),
            range: range(.last7),
            calendar: calendar
        )

        XCTAssertEqual(insights.averageCalories, 2_000, accuracy: 0.001)
        XCTAssertEqual(insights.health.suspectCount, 1)
        XCTAssertEqual(insights.health.needsDetailCount, 1)
        XCTAssertEqual(insights.health.correctedCount, 1)
        XCTAssertEqual(insights.health.chatCount, 1)
        XCTAssertEqual(insights.health.captureCount, 1)
        XCTAssertEqual(insights.health.composerCount, 3)
    }

    // MARK: - The balance table

    func testBalanceTableHoldsAllEightNutrientsInTheFixedOrder() {
        let insights = MealInsights.build(
            meals: [meal(daysAgo: 0)],
            targets: targets(),
            range: range(.last7),
            calendar: calendar
        )
        XCTAssertEqual(insights.balance.map(\.nutrient), Nutrient.balanceTableOrder)
        XCTAssertEqual(insights.balance.count, 8)
    }

    /// The band reads the SAME rows the panel prints. This is what makes it
    /// impossible for the two halves of the card to show different numbers.
    func testCollapsedPreviewRowsAreTheSameRowsAsTheTable() {
        let meals = (0..<7).map { meal(daysAgo: $0, protein: 40, sodium: 4_000) }
        let insights = MealInsights.build(
            meals: meals,
            targets: targets(),
            range: range(.last7),
            calendar: calendar
        )
        XCTAssertFalse(insights.flaggedBalance.isEmpty)
        for row in insights.flaggedBalance {
            XCTAssertTrue(insights.balance.contains(row), "\(row.nutrient) is not the table's own row")
        }
        XCTAssertLessThanOrEqual(insights.flaggedBalance.count, 3)
    }

    // MARK: - No targets

    /// Averages and the chart render; the target line and the table do not.
    func testWithNoTargetsTheTableIsAbsentAndTheAveragesStillCompute() {
        let meals = (0..<7).map { meal(daysAgo: $0, calories: 1_800) }
        let insights = MealInsights.build(
            meals: meals,
            targets: nil,
            range: range(.last7),
            calendar: calendar
        )

        XCTAssertTrue(insights.balance.isEmpty, "the table must be absent, not eight blank verdicts")
        XCTAssertTrue(insights.callouts.isEmpty, "over and under are undefined with no target")
        XCTAssertNil(insights.calorieTarget, "no target line to draw")
        XCTAssertFalse(insights.hasTargets)
        XCTAssertEqual(insights.averageCalories, 1_800, accuracy: 0.001)
        XCTAssertEqual(insights.buckets.count, 7, "the chart still draws")
        XCTAssertEqual(insights.health.daysLogged, 7, "no target means no day can be partial on calories")
    }

    /// A targets record of all zeroes is not a target. It must read the same as
    /// no record at all, or the table fills with eight divisions by zero.
    func testAllZeroTargetsReadAsNoTargets() {
        let zeroed = MealTargets()
        let insights = MealInsights.build(
            meals: [meal(daysAgo: 0)],
            targets: zeroed,
            range: range(.last7),
            calendar: calendar
        )
        XCTAssertTrue(insights.balance.isEmpty)
        XCTAssertNil(insights.calorieTarget)
    }

    // MARK: - Callouts

    /// Three is a cap, not a target: a list of eight problems is a list of zero.
    func testCalloutsAreCappedAtThree() {
        // Every one of the eight misses its band.
        let meals = (0..<7).map {
            meal(
                daysAgo: $0,
                calories: 3_400, protein: 30, carbs: 500, fat: 140,
                fibre: 5, sugar: 200, sodium: 6_000, satFat: 70
            )
        }
        let insights = MealInsights.build(
            meals: meals,
            targets: targets(),
            range: range(.last7),
            calendar: calendar
        )
        XCTAssertEqual(insights.balance.filter { $0.band?.isFlagged == true }.count, 8)
        XCTAssertEqual(insights.callouts.count, 3)
        XCTAssertEqual(insights.consistency.count, 3, "one strip per callout")
    }

    /// Weighted by priority, so a protein shortfall outranks a larger raw
    /// deviation on a nutrient nobody can act on directly.
    func testCalloutRankingWeightsProteinAboveCalories() {
        // Protein 80% of target: deviation 0.20, weight 3, score 0.60.
        // Calories 130% of target: deviation 0.30, weight 1, score 0.30.
        let meals = (0..<7).map { meal(daysAgo: $0, calories: 2_600, protein: 80) }
        let insights = MealInsights.build(
            meals: meals,
            targets: targets(),
            range: range(.last7),
            calendar: calendar
        )
        XCTAssertEqual(insights.callouts.first?.nutrient, .protein)
        XCTAssertTrue(insights.callouts.contains { $0.nutrient == .calories })
        let proteinScore = insights.callouts.first { $0.nutrient == .protein }?.score ?? 0
        let calorieScore = insights.callouts.first { $0.nutrient == .calories }?.score ?? 0
        XCTAssertGreaterThan(proteinScore, calorieScore)
    }

    /// An average alone cannot tell a steady shortfall from a fine fortnight
    /// with two bad days. The day count is what separates them.
    func testCalloutCarriesAConsistencyCount() {
        var meals: [LocalMeal] = []
        for offset in 0..<12 { meals.append(meal(daysAgo: offset, protein: 60)) }
        for offset in 12..<14 { meals.append(meal(daysAgo: offset, protein: 120)) }

        let insights = MealInsights.build(
            meals: meals,
            targets: targets(),
            range: range(.last30),
            calendar: calendar
        )

        let protein = insights.callouts.first { $0.nutrient == .protein }
        XCTAssertNotNil(protein)
        XCTAssertEqual(protein?.matchingDays, 12)
        XCTAssertEqual(protein?.consideredDays, 14)
        XCTAssertEqual(protein?.band, .under)
        XCTAssertTrue(
            protein?.text.contains("12 of the last 14 logged days were below target") == true,
            "got: \(protein?.text ?? "nil")"
        )
    }

    /// Every sentence is written in Swift from the computed row. Nothing here
    /// touches a network, so the wording is identical across sessions and can
    /// never contradict the table above it.
    func testCalloutSentencesAreGeneratedFromTheRow() {
        let row = MealBalanceRow(
            nutrient: .protein, average: 88, target: 140, ratio: 88 / 140, band: .under
        )
        XCTAssertEqual(
            MealInsights.sentence(row: row, band: .under, matching: 12, considered: 14),
            "Protein is 52 g a day under target, and 12 of the last 14 logged days were below target."
        )

        let calories = MealBalanceRow(
            nutrient: .calories, average: 2_400, target: 2_000, ratio: 1.2, band: .over
        )
        XCTAssertEqual(
            MealInsights.sentence(row: calories, band: .over, matching: 5, considered: 7),
            "Calories are 400 kcal a day over target, and 5 of the last 7 logged days were above target."
        )
    }

    // MARK: - Chart and strips

    func testDailyChartDrawsOneBucketPerDayAndCarriesTheTarget() {
        let meals = (0..<7).map { meal(daysAgo: $0, calories: 2_100) }
        let insights = MealInsights.build(
            meals: meals,
            targets: targets(),
            range: range(.last7),
            calendar: calendar
        )
        XCTAssertEqual(insights.granularity, .daily)
        XCTAssertEqual(insights.buckets.count, 7)
        XCTAssertEqual(insights.calorieTarget, 2_000)
        for bucket in insights.buckets {
            XCTAssertEqual(bucket.averageCalories, 2_100, accuracy: 0.001)
            XCTAssertEqual(bucket.countedDays, 1)
        }
    }

    /// A long window buckets rather than drawing 90 bars, exactly as Finance
    /// does, and each bar stays an average per day so the target rule across it
    /// still means something.
    func testLongWindowBucketsWeeklyAndKeepsBarsPerDay() {
        let meals = (0..<90).map { meal(daysAgo: $0, calories: 2_100) }
        let insights = MealInsights.build(
            meals: meals,
            targets: targets(),
            range: range(.last90),
            calendar: calendar
        )
        XCTAssertEqual(insights.granularity, .weekly)
        XCTAssertEqual(insights.buckets.count, 13)
        for bucket in insights.buckets {
            XCTAssertEqual(bucket.averageCalories, 2_100, accuracy: 0.001)
        }
    }

    /// One cell per day, and the long window says it is showing the recent end
    /// rather than letting the reader assume it is all of it.
    func testConsistencyStripIsOneCellPerDayAndClipsALongWindow() {
        let short = MealInsights.build(
            meals: (0..<7).map { meal(daysAgo: $0, protein: 20) },
            targets: targets(),
            range: range(.last7),
            calendar: calendar
        )
        let strip = short.consistency.first { $0.nutrient == .protein }
        XCTAssertEqual(strip?.cells.count, 7)
        XCTAssertFalse(strip?.isClipped ?? true)
        XCTAssertEqual(strip?.cells.compactMap(\.band).count, 7)

        let long = MealInsights.build(
            meals: (0..<90).map { meal(daysAgo: $0, protein: 20) },
            targets: targets(),
            range: range(.last90),
            calendar: calendar
        )
        let longStrip = long.consistency.first { $0.nutrient == .protein }
        XCTAssertEqual(longStrip?.cells.count, MealInsights.consistencyCellLimit)
        XCTAssertFalse(longStrip?.isClipped ?? false, "90 days is exactly the limit, not past it")
    }

    /// An unlogged day has no verdict, so its cell is blank rather than green.
    func testUnloggedDaysLeaveBlankCells() {
        let insights = MealInsights.build(
            meals: [meal(daysAgo: 0, protein: 20), meal(daysAgo: 1, protein: 20)],
            targets: targets(),
            range: range(.last7),
            calendar: calendar
        )
        let strip = insights.consistency.first { $0.nutrient == .protein }
        XCTAssertEqual(strip?.cells.count, 7)
        XCTAssertEqual(strip?.cells.filter { $0.band == nil }.count, 5)
    }

    // MARK: - Meal types

    /// The actionable fact usually hides here: a snack share no per-nutrient
    /// row would ever surface.
    func testAverageCaloriesByMealTypeSplitsTheDay() {
        var meals: [LocalMeal] = []
        for offset in 0..<7 {
            meals.append(meal(daysAgo: offset, calories: 600, type: .breakfast))
            meals.append(meal(daysAgo: offset, calories: 600, type: .lunch))
            meals.append(meal(daysAgo: offset, calories: 0, type: .dinner))
            meals.append(meal(daysAgo: offset, calories: 800, type: .snack))
        }
        let insights = MealInsights.build(
            meals: meals,
            targets: targets(),
            range: range(.last7),
            calendar: calendar
        )
        XCTAssertEqual(insights.byMealType.map(\.mealType), MealDaySummary.typeOrder)
        let snack = insights.byMealType.first { $0.mealType == .snack }
        XCTAssertEqual(snack?.averageCalories ?? 0, 800, accuracy: 0.001)
        XCTAssertEqual(snack?.share ?? 0, 800.0 / 2_000.0, accuracy: 0.001)
    }

    // MARK: - Recompute

    /// Editing an old meal's calories moves the window's average. The build is
    /// pure, so a second build over the edited rows is the whole proof.
    func testEditingAnOldMealMovesTheAverage() {
        let meals = (0..<28).map { meal(daysAgo: $0, calories: 2_000) }
        let before = MealInsights.build(
            meals: meals, targets: targets(), range: range(.last30), calendar: calendar
        )
        XCTAssertEqual(before.averageCalories, 2_000, accuracy: 0.001)

        // Three weeks old, inside the 30-day window.
        meals[21].calories = 4_800
        let after = MealInsights.build(
            meals: meals, targets: targets(), range: range(.last30), calendar: calendar
        )
        XCTAssertEqual(after.averageCalories, (27 * 2_000 + 4_800) / 28, accuracy: 0.001)
        XCTAssertNotEqual(before.averageCalories, after.averageCalories)
    }

    // MARK: - Periods

    /// Seven days by default, deliberately unlike Finance's this-month.
    func testDefaultPeriodIsSevenDays() {
        let selection = MealTrendSelection()
        XCTAssertEqual(selection.period, .last7)
        let window = selection.resolvedRange(now: now, calendar: calendar)
        let days = (calendar.dateComponents(
            [.day],
            from: calendar.startOfDay(for: window.lowerBound),
            to: calendar.startOfDay(for: window.upperBound)
        ).day ?? 0) + 1
        XCTAssertEqual(days, 7)
    }

    /// The rolling presets hold as many days as they name, and no window runs
    /// past today — an unlived day is not an unlogged one.
    func testPresetWindowsHoldTheDaysTheyName() {
        for (period, expected) in [(MealTrendPeriod.last7, 7), (.last30, 30), (.last90, 90)] {
            let window = MealTrendSelection(period: period).resolvedRange(now: now, calendar: calendar)
            let days = (calendar.dateComponents(
                [.day],
                from: calendar.startOfDay(for: window.lowerBound),
                to: calendar.startOfDay(for: window.upperBound)
            ).day ?? 0) + 1
            XCTAssertEqual(days, expected, "\(period)")
            XCTAssertEqual(calendar.startOfDay(for: window.upperBound), today, "\(period) must end today")
        }

        for period in [MealTrendPeriod.thisMonth, .thisYear] {
            let window = MealTrendSelection(period: period).resolvedRange(now: now, calendar: calendar)
            XCTAssertEqual(calendar.startOfDay(for: window.upperBound), today, "\(period) must end today")
        }
    }

    /// A custom range whose end is in the future is clamped, not inverted.
    func testCustomRangeClampsToToday() {
        let future = calendar.date(byAdding: .day, value: 40, to: today) ?? today
        let selection = MealTrendSelection(
            period: .custom,
            customStart: day(agoBy: 5),
            customEnd: future
        )
        let window = selection.resolvedRange(now: now, calendar: calendar)
        XCTAssertEqual(calendar.startOfDay(for: window.upperBound), today)
        XCTAssertEqual(calendar.startOfDay(for: window.lowerBound), day(agoBy: 5))
    }

    // MARK: - Ask Dexter

    /// The prompt is built from the computed value, so the question the model
    /// is asked cannot disagree with the screen it is asked from.
    func testChatPromptCarriesTheComputedFigures() {
        let meals = (0..<7).map { meal(daysAgo: $0, protein: 60) }
        let insights = MealInsights.build(
            meals: meals, targets: targets(), range: range(.last7), calendar: calendar
        )
        let prompt = insights.chatPrompt(periodLabel: "Last 7 days")
        XCTAssertTrue(prompt.contains("last 7 days"))
        XCTAssertTrue(prompt.contains("Averages against target:"))
        XCTAssertTrue(prompt.contains("Protein"))
        for callout in insights.callouts {
            XCTAssertTrue(prompt.contains(callout.text))
        }
    }
}
