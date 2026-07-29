import Foundation

#if os(macOS)

/// Reads the Apple Notes library via AppleScript (#396).
///
/// macOS only, and not by choice: Apple ships no API for reading Notes on iOS, so
/// browsing folders and notes cannot exist on the iPhone at all. Imported notes
/// reach the phone through the existing iCloud Drive sync instead.
///
/// ## Why `osascript` in a subprocess rather than `NSAppleScript`
///
/// `NSAppleScript` is documented as main-thread-bound and blocks for as long as
/// the script runs. The metadata sweep over a real library takes about six
/// seconds and a single image-heavy note body can be 32 MB, so running either
/// on the main thread would freeze the window. A subprocess is cancellable, keeps
/// the parse out of our address space until we read the pipe, and cannot wedge
/// the UI. The Apple Events permission prompt is still attributed to Dexter,
/// because it is the responsible process for the spawn.
enum AppleNotesReader {

    // MARK: - Types

    struct NoteRef: Identifiable, Hashable {
        /// The Notes-internal id, e.g. `x-coredata://…/ICNote/p1064`. Stable
        /// across runs, which is what makes re-import dedup possible.
        let id: String
        let name: String
        let created: Date?
        let modified: Date?
    }

    struct Folder: Identifiable, Hashable {
        let id: String
        let name: String
        var notes: [NoteRef]
    }

    struct NoteBody {
        let html: String
        /// Total attachments Notes reports, including non-images. The converter
        /// compares this against the inline images it found so the import can
        /// report what it could not carry across.
        let attachmentCount: Int
    }

    enum ReaderError: LocalizedError {
        case notAuthorized
        case notesAppUnavailable
        case script(String)

        var errorDescription: String? {
            switch self {
            case .notAuthorized:
                return """
                Dexter needs permission to read the Notes app. Open System \
                Settings › Privacy & Security › Automation, find Dexter, and \
                switch on Notes.
                """
            case .notesAppUnavailable:
                return "Couldn't reach the Notes app. Is it installed?"
            case .script(let message):
                return "Notes returned an error: \(message)"
            }
        }
    }

    // MARK: - Delimiters
    //
    // ASCII unit/record separators rather than tabs and newlines. A note's NAME is
    // arbitrary user text and routinely contains both, so any printable delimiter
    // would corrupt the parse on somebody's real note.
    private static let unitSeparator = "\u{1F}"
    private static let recordSeparator = "\u{1E}"

    // MARK: - Library sweep

    /// Every folder and the notes inside it, without bodies.
    ///
    /// Bodies are deliberately NOT fetched here. They carry inlined base64 image
    /// data, so a whole-library fetch would move hundreds of megabytes to build a
    /// picker; they are read one note at a time at import instead. Attachment
    /// counts are skipped for the same reason: counting them across the library
    /// costs seconds and is only needed for the notes actually chosen.
    static func library() async throws -> [Folder] {
        let script = """
        set us to (ASCII character 31)
        set rs to (ASCII character 30)
        tell application "Notes"
            set out to ""
            repeat with f in folders
                set fid to (id of f) as text
                set fname to (name of f) as text
                repeat with n in notes of f
                    set d1 to (creation date of n)
                    set d2 to (modification date of n)
                    set out to out & fid & us & fname & us & ((id of n) as text) & us & ((name of n) as text) & us & my stamp(d1) & us & my stamp(d2) & rs
                end repeat
            end repeat
            return out
        end tell

        -- Emit a locale-proof timestamp. AppleScript's date-to-string is localised
        -- and its epoch arithmetic needs a date literal that only parses in some
        -- locales, so the components are written out explicitly instead.
        on stamp(d)
            set y to year of d as integer
            set m to (month of d as integer)
            set dd to day of d as integer
            set hh to hours of d as integer
            set mi to minutes of d as integer
            set ss to seconds of d as integer
            return (y as text) & "-" & my pad(m) & "-" & my pad(dd) & " " & my pad(hh) & ":" & my pad(mi) & ":" & my pad(ss)
        end stamp

        on pad(n)
            if n < 10 then return "0" & (n as text)
            return n as text
        end pad
        """

        let output = try await run(script: script)
        return parseLibrary(output)
    }

    /// One note's body HTML plus its attachment count.
    static func body(noteID: String) async throws -> NoteBody {
        // The id is a Core Data URI produced by Notes, so it holds no quotes to
        // escape, but escape anyway rather than trusting that.
        let escaped = noteID
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        let script = """
        tell application "Notes"
            set n to note id "\(escaped)"
            return ((count of attachments of n) as text) & (ASCII character 31) & ((body of n) as text)
        end tell
        """
        let output = try await run(script: script)
        guard let separator = output.range(of: unitSeparator) else {
            // No separator means the script produced something unexpected; treat
            // the whole payload as the body rather than losing the note.
            return NoteBody(html: output, attachmentCount: 0)
        }
        let count = Int(output[output.startIndex..<separator.lowerBound].trimmingCharacters(
            in: .whitespacesAndNewlines
        )) ?? 0
        return NoteBody(html: String(output[separator.upperBound...]), attachmentCount: count)
    }

    // MARK: - Parsing

    private static func parseLibrary(_ output: String) -> [Folder] {
        var byFolder: [String: Folder] = [:]
        var order: [String] = []

        for record in output.components(separatedBy: recordSeparator) {
            let fields = record.components(separatedBy: unitSeparator)
            guard fields.count >= 6 else { continue }
            let folderID = fields[0]
            let folderName = fields[1]
            let note = NoteRef(
                id: fields[2],
                name: fields[3].isEmpty ? "Untitled" : fields[3],
                created: parseStamp(fields[4]),
                modified: parseStamp(fields[5])
            )
            if byFolder[folderID] == nil {
                byFolder[folderID] = Folder(id: folderID, name: folderName, notes: [])
                order.append(folderID)
            }
            byFolder[folderID]?.notes.append(note)
        }
        return order.compactMap { byFolder[$0] }
    }

    /// Parse `YYYY-MM-DD HH:MM:SS`, written by the script above in LOCAL time
    /// because that is the only thing AppleScript's date components report.
    private static func parseStamp(_ raw: String) -> Date? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return stampFormatter.date(from: trimmed)
    }

    private static let stampFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone.current
        return f
    }()

    // MARK: - Subprocess

    /// Run `script` through `osascript` off the main actor.
    ///
    /// Reads stdout to completion BEFORE waiting for exit. A note body can exceed
    /// the pipe buffer by orders of magnitude, and waiting first would deadlock
    /// with the child blocked on a full pipe.
    private static func run(script: String) async throws -> String {
        try await Task.detached(priority: .userInitiated) { () throws -> String in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            process.arguments = ["-"]

            let stdin = Pipe()
            let stdout = Pipe()
            let stderr = Pipe()
            process.standardInput = stdin
            process.standardOutput = stdout
            process.standardError = stderr

            try process.run()
            stdin.fileHandleForWriting.write(Data(script.utf8))
            stdin.fileHandleForWriting.closeFile()

            let outData = stdout.fileHandleForReading.readDataToEndOfFile()
            let errData = stderr.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()

            if process.terminationStatus != 0 {
                let message = String(data: errData, encoding: .utf8) ?? ""
                // -1743 is TCC refusing the Apple Event, which is a permission
                // problem the user can fix, not a bug. Distinguished so the UI can
                // say where to go rather than showing a raw AppleScript error.
                if message.contains("-1743") || message.localizedCaseInsensitiveContains("not authorized") {
                    throw ReaderError.notAuthorized
                }
                if message.contains("-600") || message.localizedCaseInsensitiveContains("isn’t running") {
                    throw ReaderError.notesAppUnavailable
                }
                throw ReaderError.script(
                    message.trimmingCharacters(in: .whitespacesAndNewlines)
                )
            }
            return String(data: outData, encoding: .utf8) ?? ""
        }.value
    }
}

#endif
