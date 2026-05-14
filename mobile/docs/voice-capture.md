# Side-button voice capture

The iOS app ships an App Intent called **Capture to Dashboard** that takes a free-text or dictated phrase and creates a task / note / list on the dashboard without opening the app. Pair it with a 3-step Shortcut and bind that Shortcut to the iPhone Action Button (or a back-tap, Lock Screen control, Siri phrase, etc.) for one-press voice capture.

## How it works

```
Press Action Button
  -> iOS Dictate Text modal
  -> Capture to Dashboard intent (POST /api/ai/capture)
  -> Notification: "Added task: Call John (Tomorrow 3:00 PM)"
```

The server applies a **smart auto-confirm** rule:

| Server says | Notification | DB effect |
|---|---|---|
| `created` (1 CREATE_TODO/NOTE/LIST) | *Added task "Call John" — due Tomorrow 3:00 PM* | Row inserted |
| `needs_clarification` (LLM asks a question) | *<the follow-up question>* | Nothing persisted |
| `needs_review` (multiple drafts, edits, deletes) | *Drafted N items — open Dashboard to review and confirm.* | Drafts stay pending; surface in chat |
| `error` | *Couldn't capture — <reason>* | Nothing persisted |

Edits, deletes, and multi-draft batches always require explicit confirmation in the app — the side button never silently mutates existing data.

## One-time setup

1. Open the **Shortcuts** app on iPhone.
2. Tap **+** -> **Add Action**.
3. Build a 3-step shortcut:
   1. **Dictate Text**
      - *Language*: matches your speech.
      - *Stop Listening*: **After Short Pause**.
   2. **Capture to Dashboard** (under Dexter)
      - Set the *Capture* input to the magic variable from step 1 (Dictated Text).
   3. **Show Notification**
      - Body: the magic variable from step 2 (the Capture intent's result text).
4. Name the shortcut, e.g. *Quick capture*.

Bind it to the side button:

| Device | Path |
|---|---|
| iPhone 15 Pro / 16 / Ultra | Settings -> Action Button -> Shortcut -> *Quick capture* |
| iPhone 8+ (non-Action-Button) | Settings -> Accessibility -> Touch -> Back Tap -> Double Tap (or Triple Tap) -> *Quick capture* |
| Any iPhone on iOS 18+ | Long-press Lock Screen / Control Centre -> add a Shortcut control bound to *Quick capture* |
| Siri | Just say "Capture to Dashboard …" — the App Shortcut registers the phrase automatically. |

## Examples

| Spoken phrase | Result |
|---|---|
| "remind me to call John tomorrow at 3" | Task created. Notification: *Added task "Call John" — due …* |
| "note: book ideas Lisbon Tokyo Reykjavik" | Note created. |
| "shopping list eggs milk bread" | List created with three items. |
| "remind me to call John" | Notification: *When did you want to call John?* — nothing persisted. |
| "call John and add a note about the meeting" | Notification: *Drafted 2 items — open Dashboard to review and confirm.* |

## Why a wrapping Shortcut and not just the App Intent

When iOS runs an App Intent with a required `String` parameter directly from the Action Button (no Shortcut wrapping), the value-input UI is the **keyboard**, not dictation. The 3-step Shortcut wraps **Dictate Text** before the intent so the runtime UX is voice-first. One-time 30-second setup; from that point on it's a single press.
