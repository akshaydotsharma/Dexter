import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

/// The two other ways to say what a meal is: show it, or say it out loud
/// (#627).
///
/// ### Why they live inside the field and not in the control row
///
/// The composer already has a row of controls under the description — the meal
/// type, Find an item, Estimate — and two more buttons in it would make four
/// controls of equal weight where only one of them is the action. These two are
/// not actions. They are alternative ways of FILLING the field above them, which
/// is why they sit inside its border, at the trailing edge, at icon size. A
/// photograph and a dictation both end up in the same place a typed sentence
/// does: the estimate's input.
///
/// ### Why one plus and not two buttons
///
/// "Take a photo" and "Choose a picture" are the same intention at two sources,
/// and the phone is the only place the distinction exists at all. One plus asks
/// the question once; the sheet behind it answers where from. On a Mac there is
/// no camera path, so the plus opens the library directly and asks nothing.
///
/// ### Both buttons are on both platforms
///
/// The microphone used to be iOS-only, because the Mac target did not compile
/// the voice stack at all. It does now (#640), so the pair is the same pair
/// everywhere; only the plus behaves differently, and only because a Mac has no
/// camera to offer.
struct MealCaptureAccessories: View {

    @Binding var text: String
    @Binding var photos: [MealPhoto]

    /// Off while an estimate is in flight. The inputs to a call that is already
    /// running are not editable, and a mic opened mid-estimate would be
    /// dictating into a field whose contents have already been sent.
    var isEnabled: Bool = true

    /// Where a failure is reported, and where a `nil` withdraws it.
    ///
    /// Both accessories report through this one closure, so a surface adopting
    /// them has exactly one place to render "that didn't work" rather than one
    /// per input. It is deliberately NOT the estimate's own failure state: a
    /// photo that would not decode and a microphone with no permission are
    /// problems with the INPUT, and offering "Try again" or "Log it without
    /// numbers" for either would be answering a question nobody asked.
    var onError: (String?) -> Void

    /// The side of each button, and the glyph drawn inside it (#631).
    ///
    /// The composer carries them at 28pt because they live INSIDE the border of
    /// a text box, in a gutter charged against the field's width. The plan chat
    /// carries them in an input bar, which is a row of 40pt controls ending in a
    /// send disc, and a 28pt pair there reads as two smaller buttons from
    /// somewhere else rather than as part of the row.
    ///
    /// Same component, two scales. The alternative was a second pair of buttons
    /// for the second surface, which is how two answers to one question start.
    var side: CGFloat = 28
    var glyphSize: CGFloat = 17

    /// What a reader is told the two buttons do.
    ///
    /// The composer's defaults name the meal, because on that surface the photo
    /// IS the meal being logged. In the plan chat the same photo is as likely to
    /// be a fridge shelf or a menu, and a label that insisted it was a meal
    /// would be describing a different feature (#631).
    var photoLabel: String = "Add a photo of the meal"
    var micLabel: String = "Dictate the meal"

    @State private var showingSourceChoice = false
    @State private var showingLibrary = false
    @State private var isPreparing = false
    #if os(iOS)
    @State private var showingCamera = false
    #endif

    /// The cap, and the reason there is one.
    ///
    /// Three plates cover the case this feature exists for: a main, a side and a
    /// drink photographed separately, or one meal shot twice because the first
    /// frame missed half of it. Past that, each image is a full-size base64 blob
    /// in one request body, and the ceiling is Anthropic's rather than anything
    /// this app can raise.
    static let maxPhotos = 3

    private var canAddPhoto: Bool { isEnabled && !isPreparing && photos.count < Self.maxPhotos }

    var body: some View {
        HStack(spacing: Space.xs) {
            photoButton
            // Both platforms since #640. The Mac compiles the voice stack now,
            // records through `AVAudioEngine`'s default input device, and owns
            // its single transcriber from `DexterMacApp` — so there is nothing
            // left here that was ever iOS-shaped.
            MealDictationButton(
                text: $text,
                isEnabled: isEnabled,
                onError: onError,
                side: side,
                glyphSize: glyphSize,
                label: micLabel
            )
        }
        #if os(iOS)
        .confirmationDialog("Add a photo", isPresented: $showingSourceChoice, titleVisibility: .visible) {
            Button("Take a photo") { showingCamera = true }
            Button("Choose a picture") { showingLibrary = true }
            Button("Cancel", role: .cancel) {}
        }
        .fullScreenCover(isPresented: $showingCamera) {
            // Full screen rather than a sheet for the reason `CameraPicker`
            // gives: UIKit's camera UI is itself full-screen and fights sheet
            // detents.
            CameraPicker { data in
                showingCamera = false
                guard let data else { return }
                accept(data)
            }
            .ignoresSafeArea()
        }
        #endif
        .photoLibraryPicker(isPresented: $showingLibrary) { data in
            guard let data else { return }
            accept(data)
        }
    }

    private var photoButton: some View {
        Button {
            #if os(iOS)
            // A simulator has no camera, and offering a choice with one real
            // answer is a sheet in the way. `CameraPicker` falls back to the
            // library itself, but the user should not have to discover that
            // through a dialog that lied about the options.
            if UIImagePickerController.isSourceTypeAvailable(.camera) {
                showingSourceChoice = true
            } else {
                showingLibrary = true
            }
            #else
            showingLibrary = true
            #endif
        } label: {
            Group {
                if isPreparing {
                    ProgressView()
                        #if os(macOS)
                        .controlSize(.small)
                        #else
                        .scaleEffect(0.6)
                        #endif
                } else {
                    Image(systemName: "plus.circle")
                        .font(.system(size: glyphSize, weight: .regular))
                }
            }
            .foregroundStyle(canAddPhoto ? Tokens.muted : Tokens.mutedSoft)
            .frame(width: side, height: side)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!canAddPhoto)
        .accessibilityLabel(photos.isEmpty ? photoLabel : "\(photoLabel), \(photos.count) added")
    }

    /// Normalise the picker's bytes and put the result in the tray.
    ///
    /// The compression is awaited rather than fired and forgotten, because the
    /// plus button turns into a spinner for its duration: a photo that is still
    /// being encoded when Estimate is pressed would be silently left out of the
    /// request, and the user would be told the model could not see a picture
    /// they can see on screen.
    private func accept(_ raw: Data) {
        isPreparing = true
        Task {
            defer { isPreparing = false }
            do {
                photos.append(try await MealPhoto.make(from: raw))
                // A photo that worked clears the complaint about the one that
                // did not. Leaving it up would describe a failure that is no
                // longer on screen.
                onError(nil)
            } catch {
                onError("Couldn't read that photo. \(error.localizedDescription)")
            }
        }
    }
}

/// The photos attached so far, under the field they belong to.
///
/// Thumbnails rather than a count, because the one thing that goes wrong with an
/// invisible attachment is attaching the wrong one. A count says "1 photo" for
/// both yesterday's lunch and today's; a thumbnail does not.
struct MealPhotoStrip: View {

    @Binding var photos: [MealPhoto]

    /// The photo being looked at full size, or nil.
    ///
    /// A 56pt thumbnail settles "there is a photo attached" and nothing else. It
    /// cannot settle "is that the RIGHT photo", which is the question that
    /// matters when the picture is about to be the entire input to an estimate:
    /// two plates from the same lunch look identical at 56pt, and a photo
    /// attached by mistake is only visible once it is big.
    @State private var viewing: MealPhoto?

    /// Shown beside the thumbnails when the field is empty, which is the case
    /// where the photo is the entire input and the user is about to spend a
    /// call on it.
    var note: String?

    private let side: CGFloat = 56

    var body: some View {
        VStack(alignment: .leading, spacing: Space.xs) {
            HStack(spacing: Space.sm) {
                ForEach(photos) { photo in
                    thumbnail(photo)
                }
                Spacer(minLength: 0)
            }
            if let note {
                Text(note)
                    .font(.edCaption)
                    .foregroundStyle(Tokens.mutedSoft)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .sheet(item: $viewing) { photo in
            MealPhotoViewer(photo: photo)
        }
    }

    @ViewBuilder
    private func thumbnail(_ photo: MealPhoto) -> some View {
        let image = PlatformImage(data: photo.jpegData)
        ZStack(alignment: .topTrailing) {
            Button {
                // Only offer the viewer for a photo that decoded. Opening a
                // full-screen sheet onto the same grey placeholder the thumbnail
                // is already showing would answer nothing.
                if image != nil { viewing = photo }
            } label: {
                thumbnailFace(image)
            }
            .buttonStyle(.plain)
            .disabled(image == nil)
            .accessibilityLabel("Attached photo of the meal")
            .accessibilityHint(image == nil ? "" : "Opens it full size")

            removeButton(photo)
        }
    }

    @ViewBuilder
    private func thumbnailFace(_ image: PlatformImage?) -> some View {
        Group {
            Group {
                if let image {
                    Image(platformImage: image)
                        .resizable()
                        .scaledToFill()
                } else {
                    // The bytes came out of a compressor that had already
                    // decoded them, so this is close to unreachable. It renders
                    // a placeholder rather than nothing so a photo that cannot
                    // be drawn is still visibly attached and still removable.
                    Tokens.surface2
                        .overlay(
                            Image(systemName: "photo")
                                .font(.system(size: 16))
                                .foregroundStyle(Tokens.mutedSoft)
                        )
                }
            }
            .frame(width: side, height: side)
            .clipShape(RoundedRectangle(cornerRadius: Radius.sm, style: .continuous))
            .paperBorder(Tokens.border, radius: Radius.sm)
        }
        // The tap target is the tile, not the drawn image inside it, so the
        // corners a `scaledToFill` crop leaves bare still open the viewer.
        .contentShape(RoundedRectangle(cornerRadius: Radius.sm, style: .continuous))
    }

    private func removeButton(_ photo: MealPhoto) -> some View {
        Button {
            photos.removeAll { $0.id == photo.id }
        } label: {
            Image(systemName: "xmark.circle.fill")
                .font(.system(size: 15, weight: .regular))
                .symbolRenderingMode(.palette)
                .foregroundStyle(Tokens.surface, Tokens.inkSoft)
                .padding(4)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .offset(x: 6, y: -6)
        .accessibilityLabel("Remove this photo")
    }
}

/// One attached photo, full size (#627).
///
/// ### Why it reuses the ticket viewer's parts rather than the ticket viewer
///
/// `TicketOriginalViewer` reads from `TicketStorage` by relative path, handles
/// PDFs, and knows about assets that have not synced to this device yet. A meal
/// photo is none of those: it is a JPEG in memory that will be gone in a minute.
/// So this takes the two pieces that ARE shared — `PinchZoomImageView` for the
/// real platform gestures and `ZoomControls` for the mouse users who have none —
/// and skips the storage layer entirely.
struct MealPhotoViewer: View {

    let photo: MealPhoto

    @Environment(\.dismiss) private var dismiss

    /// Driven by the zoom buttons, which on macOS are the only way in for a
    /// mouse.
    @State private var scale: CGFloat = PinchZoomImageView.minScale

    var body: some View {
        NavigationStack {
            ZStack {
                Tokens.paper.ignoresSafeArea()
                content
            }
            .navigationTitle("Attached photo")
            .inlineNavigationTitle()
            .toolbar {
                #if os(macOS)
                ToolbarItem(placement: .automatic) {
                    if image != nil { ZoomControls(scale: $scale) }
                }
                #endif
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                        .foregroundStyle(Tokens.ink)
                }
            }
        }
        #if os(macOS)
        // Without an explicit size a macOS sheet shrinks to its content's ideal
        // width, which for a scroll-view-backed image is next to nothing: the
        // photo would open as a thumbnail in a box barely taller than its own
        // toolbar, which is the thing this view exists to stop being (#474).
        .frame(minWidth: 520, idealWidth: 680, minHeight: 520, idealHeight: 760)
        #endif
    }

    private var image: PlatformImage? { PlatformImage(data: photo.jpegData) }

    @ViewBuilder
    private var content: some View {
        if let image {
            PinchZoomImageView(image: image, scale: $scale)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .ignoresSafeArea(edges: .bottom)
        } else {
            // Close to unreachable: these bytes came out of a compressor that
            // had already decoded them. It says the honest thing rather than
            // showing an empty box.
            Text("This photo can no longer be displayed.")
                .font(.edBody)
                .foregroundStyle(Tokens.muted)
        }
    }
}

/// Tap to dictate, tap again to stop (#627).
///
/// ### Why it stops only when asked
///
/// The chat mic auto-finalises after a stretch of silence, which suits a message
/// you are about to send. A meal is dictated in pieces — you look at the plate,
/// you remember the drink, you work out whether that was one slice or two — and
/// a mic that closes during the thinking pause makes the user tap it three times
/// for one meal. This one stays open until it is told to stop, which is what was
/// asked for.
///
/// ### Why the field fills a phrase at a time
///
/// It mirrors `transcript`, which holds only utterances the engine has finalised
/// and normalised, and never `provisionalText`, which holds raw deltas. The
/// reason is the one `SpeechTranscriber` states: the raw stream can carry
/// pre-normalisation script, and typing that into a field the user is about to
/// submit puts Urdu characters in a meal description. Server VAD finalises on
/// each pause, so text lands in phrases as you speak rather than all at the end.
///
/// ### Why it watches the session id
///
/// There is one transcriber in the app and the global voice overlay can take it
/// at any moment — it is a `fullScreenCover`, so this view stays mounted and its
/// observers keep firing underneath. Snapshotting `transcriber.sessionID` at
/// start and refusing to mirror once it moves is what stops the overlay's words
/// appearing in the meal field. See the note on that property.
///
/// The Mac has no such overlay, but it has the same one transcriber and it can
/// have two of these buttons mounted at once — the plan chat panel floats over
/// the plan while the entry sheet is open on top of it — so the guard earns its
/// place on both platforms (#640).
struct MealDictationButton: View {

    @Binding var text: String
    var isEnabled: Bool = true

    /// Where a microphone failure is reported, and where a `nil` withdraws it.
    ///
    /// Without this the button is silent on the one failure that actually
    /// happens: permission. `SpeechTranscriber` sets `errorMessage` and returns
    /// without recording, so a user who has denied the microphone taps a mic
    /// that does nothing at all and has no way to learn why. Chat renders the
    /// same string inline; this hands it to whoever owns the field.
    var onError: (String?) -> Void = { _ in }

    /// Matches whatever the surface hosting it draws its other controls at. See
    /// the note on `MealCaptureAccessories.side` (#631).
    var side: CGFloat = 28
    var glyphSize: CGFloat = 17

    /// What a reader is told this button does when it is idle. See the note on
    /// `MealCaptureAccessories.photoLabel` (#631).
    var label: String = "Dictate the meal"

    /// The one shared transcriber, from the app-level owner. There is never a
    /// second instance: a duplicate would install a second audio tap and trip
    /// the AVAudioEngine assertion #150 was filed for.
    @Environment(VoiceCaptureViewModel.self) private var voiceVM
    private var transcriber: SpeechTranscriber { voiceVM.transcriber }

    /// Whatever was in the field when the mic opened. Speech APPENDS to this
    /// rather than replacing it, so dictating an afterthought onto a typed
    /// description does not delete the description.
    @State private var baseline: String = ""

    /// The transcriber session this button started, or nil when it owns none.
    @State private var ownedSession: Int?

    /// `didFinalizeTranscript` at the moment the session opened, so a final
    /// left over from a previous owner is not mistaken for this one's.
    @State private var finalizeBaseline: Int = 0

    private var isMine: Bool { ownedSession == transcriber.sessionID }
    private var isListening: Bool { isMine && transcriber.isRecording }

    var body: some View {
        Button {
            Task { await toggle() }
        } label: {
            Image(systemName: isListening ? "stop.circle.fill" : "mic")
                .font(.system(size: glyphSize, weight: .regular))
                .foregroundStyle(tint)
                .frame(width: side, height: side)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled && !isListening)
        .accessibilityLabel(isListening ? "Stop dictating" : label)
        .accessibilityHint(isListening ? "" : "Listens until you tap it again")
        .onChange(of: transcriber.transcript) { _, _ in mirror() }
        .onChange(of: transcriber.didFinalizeTranscript) { _, _ in
            // The authoritative text for this session has landed. Mirror it,
            // then close the session — but ONLY once the mic has actually
            // stopped. While it is still recording, server VAD finalises every
            // pause, and closing on the first one would drop every phrase after
            // it (the bug #151 fixed in chat).
            guard isMine, transcriber.didFinalizeTranscript > finalizeBaseline else { return }
            mirror()
            if !transcriber.isRecording { endSession() }
        }
        .onDisappear {
            // Leaving the surface must not leave the microphone open, and a
            // transcript that lands afterwards must not write into a field
            // nobody is looking at.
            if isListening { transcriber.stop() }
            endSession()
        }
    }

    private var tint: Color {
        if isListening { return Tokens.danger }
        return isEnabled ? Tokens.muted : Tokens.mutedSoft
    }

    private func toggle() async {
        if isListening {
            // `stop()` is synchronous but the OpenAI final arrives after it, so
            // the session stays open to catch it. `didFinalizeTranscript` above
            // is what closes it.
            transcriber.stop()
            return
        }
        guard isEnabled else { return }
        // A new attempt withdraws the last attempt's complaint, so the user is
        // never reading an error about a tap two taps ago.
        onError(nil)
        // Snapshot BEFORE starting: `start()` clears `transcript`, and the
        // baseline has to describe the field as it was, not as it will be.
        baseline = text
        finalizeBaseline = transcriber.didFinalizeTranscript
        await transcriber.toggle()
        // Claim the session the start just created. Read after the await
        // because the id is bumped inside `start()`; a value read before it
        // would name the PREVIOUS session and nothing would ever mirror.
        ownedSession = transcriber.sessionID
        // `start()` reports permission and audio-engine failures by setting
        // this and returning, rather than by throwing, so the only way to know
        // the mic never opened is to ask afterwards.
        if !transcriber.isRecording, let failure = transcriber.errorMessage {
            onError(failure)
            endSession()
        }
    }

    private func endSession() {
        ownedSession = nil
        baseline = ""
    }

    /// Put the session's settled text in the field, appended to the baseline.
    private func mirror() {
        guard isMine else { return }
        let spoken = transcriber.transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !spoken.isEmpty else { return }
        let base = baseline.trimmingCharacters(in: .whitespacesAndNewlines)
        text = base.isEmpty ? spoken : "\(base) \(spoken)"
    }
}
