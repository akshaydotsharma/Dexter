# GitHub issue conventions

Every issue title MUST start with one of these three prefixes:

- `[Enhancement]` — improvement to an existing feature (e.g. *[Enhancement] Improve UI of Todos widget*)
- `[Bug]` — something broken or misbehaving (e.g. *[Bug] Chat does not process long messages*)
- `[Feature]` — net-new capability (e.g. *[Feature] Build a new speech-to-text feature*)

Tag each issue with the matching label (`enhancement`, `bug`, or create/use a `feature` label).

## Inferring the type

When the user describes work without naming the type, infer it:

- Brand-new capability that didn't exist before -> `[Feature]`
- Existing behaviour is wrong, broken, or misbehaving -> `[Bug]`
- Existing feature works but could be better (UX polish, more options, faster, clearer) -> `[Enhancement]`

Never ask the user which prefix to use unless the request is genuinely ambiguous between two of the three.

## Scope

Applies to issues opened in https://github.com/akshaydotsharma/personal-dashboard via `gh issue create` or the GitHub UI. PR titles follow conventional commit prefixes (`feat:`, `fix:`, `chore:`, etc.) — they are NOT bracketed.
