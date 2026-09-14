import PDFKit
import XCTest
@testable import DexterMac

/// The report actually becomes a PDF (#528).
///
/// The model tests prove what the report says; this proves it can be handed to
/// someone. `ImageRenderer` into a PDF `CGContext` fails in ways a compile
/// cannot catch — a zero-size media box, a page that never begins — and all of
/// them produce a file rather than an error.
///
/// Set `DEXTER_REPORT_PDF_OUT` to a directory to keep a copy for eyeballing.
@MainActor
final class TripExpenseReportPDFTests: XCTestCase {

    private let priya = UUID()

    private func day(_ value: Int) -> Date {
        var components = DateComponents()
        components.year = 2026
        components.month = 6
        components.day = value
        components.hour = 12
        return Calendar.current.startOfDay(for: Calendar.current.date(from: components) ?? Date())
    }

    private func expense(
        _ index: Int,
        day dayOfMonth: Int,
        amount: Double,
        currency: String,
        paidBy: UUID? = nil,
        splits: [ExpenseSplitEntry] = [],
        isRefund: Bool = false
    ) -> LocalExpense {
        let rate = currency == "EUR" ? 1.473 : 1.0
        let categories = ["food_and_dining", "transport", "accommodation", "activities", "shopping"]
        let row = LocalExpense(
            clientUUID: "row-\(index)",
            date: day(dayOfMonth),
            category: categories[index % categories.count],
            merchant: "Merchant \(index)",
            originalAmount: amount,
            originalCurrency: currency,
            sgdAmount: amount * rate,
            fxRate: rate,
            source: "manual",
            tripUUID: UUID(),
            isRefund: isRefund,
            paidByPersonUUID: paidBy
        )
        row.splits = splits
        return row
    }

    /// A trip long enough to run past one page, with the awkward rows in it.
    private func fixture(count: Int) -> [LocalExpense] {
        (0..<count).map { index in
            expense(
                index,
                day: 3 + index % 9,
                amount: Double(20 + index * 3),
                currency: index % 3 == 0 ? "SGD" : "EUR",
                paidBy: index % 4 == 0 ? priya : nil,
                splits: index % 5 == 0
                    ? []
                    : [ExpenseSplitEntry(person: nil, shares: 1), ExpenseSplitEntry(person: priya, shares: 1)],
                isRefund: index % 11 == 0 && index > 0
            )
        }
    }

    private func report(count: Int) -> TripExpenseReport {
        let rows = fixture(count: count).sorted { $0.date > $1.date }
        let order: [SplitPartyID] = [.me, .person(priya)]
        return TripExpenseReport.make(
            TripExpenseReportInput(
                tripName: "Italy",
                startDate: day(3),
                endDate: day(12),
                allExpenses: rows,
                participantOrder: order,
                reportCurrencyCode: "SGD",
                exportDate: day(14),
                displayName: { party in
                    if case .person = party { return "Priya" }
                    return "You"
                },
                displayMoney: { String(format: "SGD %.2f", $0) },
                captureMoney: { value, code in String(format: "%@ %.2f", code, value) },
                tripRateToSGD: { $0 == "EUR" ? 1.473 : 1.0 }
            )
        )
    }

    // MARK: - Tests

    func testEveryReportOpensWithACoverPage() throws {
        let data = try TripExpenseReportPDF.data(for: report(count: 6))
        let document = try XCTUnwrap(PDFDocument(data: data), "Not a readable PDF")
        XCTAssertGreaterThanOrEqual(document.pageCount, 2, "A cover, then at least one body page")

        let cover = try XCTUnwrap(document.page(at: 0)).string ?? ""
        XCTAssertTrue(cover.contains("Italy"))
        XCTAssertTrue(cover.uppercased().contains("GROUP TOTAL"))
        XCTAssertTrue(cover.uppercased().contains("SHARE PER PERSON"), "The cover answers each person's share")
        XCTAssertTrue(cover.contains("Priya"), "Every participant is named on the cover")
        XCTAssertFalse(cover.uppercased().contains("DAILY LEDGER"), "The ledger starts on its own page")
    }

    /// A4 at 72 points per inch. A reader that resizes the page would reflow
    /// nothing, because the layout is baked, so the media box has to be right.
    func testEveryPageIsA4() throws {
        let data = try TripExpenseReportPDF.data(for: report(count: 60))
        let document = try XCTUnwrap(PDFDocument(data: data))

        for index in 0..<document.pageCount {
            let bounds = try XCTUnwrap(document.page(at: index)).bounds(for: .mediaBox)
            XCTAssertEqual(bounds.width, ReportPageMetrics.width, accuracy: 0.5)
            XCTAssertEqual(bounds.height, ReportPageMetrics.height, accuracy: 0.5)
        }
    }

    /// The text stays text. A screenshot-per-page export would still open, look
    /// fine, and be unsearchable — which is only detectable by asking for the
    /// string back.
    func testTheReportIsSelectableTextNotAPictureOfText() throws {
        let made = report(count: 24)
        let data = try TripExpenseReportPDF.data(for: made)
        let document = try XCTUnwrap(PDFDocument(data: data))
        let text = document.string ?? ""

        // Section headings print uppercase, so the comparison is too.
        let upper = text.uppercased()
        XCTAssertTrue(text.contains("Italy"), "The trip name should be readable text")
        XCTAssertTrue(upper.contains("DAILY LEDGER"), "Headings must survive extraction")
        XCTAssertTrue(upper.contains("PARTICIPANT BREAKDOWN"))
        XCTAssertTrue(upper.contains("WHO PAYS WHOM"))
        XCTAssertTrue(upper.contains("CATEGORY ANALYSIS"))
        XCTAssertTrue(text.contains("Merchant 1"))
        XCTAssertTrue(text.contains("Your cost in full"))
        // Amounts and dates are the reason `.monospacedDigit()` is off in the
        // page views: with it on, these render but extract blank.
        XCTAssertTrue(text.contains("EUR "), "Ledger amounts must be selectable text")
        XCTAssertTrue(upper.contains("SGD "), "Totals must be selectable text")

        if let out = ProcessInfo.processInfo.environment["DEXTER_REPORT_PDF_OUT"] {
            let url = URL(fileURLWithPath: out).appendingPathComponent(made.fileName)
            try? data.write(to: url)
        }
    }

    func testALongTripPaginatesRatherThanTruncating() throws {
        let short = try TripExpenseReportPDF.data(for: report(count: 6))
        let long = try TripExpenseReportPDF.data(for: report(count: 120))

        let shortPages = try XCTUnwrap(PDFDocument(data: short)).pageCount
        let longPages = try XCTUnwrap(PDFDocument(data: long)).pageCount
        XCTAssertGreaterThan(longPages, shortPages)

        // The last expense has to be in the file, not off the bottom of page 1.
        let text = try XCTUnwrap(PDFDocument(data: long)).string ?? ""
        XCTAssertTrue(text.contains("Merchant 119"))
    }

    func testTheFileIsWrittenUnderItsOwnName() throws {
        let made = report(count: 4)
        let url = try TripExpenseReportPDF.write(made)
        defer { try? FileManager.default.removeItem(at: url) }

        XCTAssertEqual(url.lastPathComponent, made.fileName)
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        XCTAssertNotNil(PDFDocument(url: url))
    }
}
