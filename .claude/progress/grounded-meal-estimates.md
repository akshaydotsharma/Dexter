# Ground meal estimates in real food data (#653)

**Status**: in-progress
**Started**: 2026-09-22
**Last Updated**: 2026-09-22 02:00 SGT
**Branch**: `feat/grounded-meal-estimates`

## Objective

Stop the model inventing both halves of a meal estimate. It should resolve each
item's density and mass from named sources, and confidence should be derived in
Swift from that provenance rather than self-reported.

## The measurement that started this

36 meals, 15 to 21 September. Of the 25 that carry a real model band: 15 low
(60%), 8 medium (32%), 2 high (8%). No model estimate has ever reached 1.0.
Every exact row came from the library or a hand-typed total.

## Completed Steps

- [x] Investigate and quantify the problem against the real store (2026-09-22)
- [x] Raise #653 with the scope and the out-of-scope list (2026-09-22)
- [x] `USDA_FDC_API_KEY` through `server/.env`, `project.yml`, `ship-lan.sh`,
      `AppConfig`. Verified live; the Mac build's signature stays valid with
      three keys injected (2026-09-22)
- [x] `FoodDataCentralClient` + 31 tests, 28 offline and 3 live. Committed as
      `d8963b7` (2026-09-22)

## Current Step

- [ ] The lookup tool on the composer's estimate call
  - Design settled: ONE batched tool, `look_up_foods({queries: [...]})`, so a
    three-dish meal costs one model round trip rather than three. The device
    fans the queries out concurrently and returns candidates already carrying
    their portion tables.
  - Not started in code.

## Next Steps

- [ ] Per-item provenance on the item schema: `density_source` (fdc / saved /
      packet / web / estimated) and `mass_source` (stated / packet_serving /
      standard_portion / history / guessed)
- [ ] Derive confidence in Swift from provenance; stop reading the model's band
- [ ] Saved-library and recent-meal blocks reach the COMPOSER prompt (today they
      reach only chat and the Shortcut, so `saved_item_id` cannot fire on the
      path that logged 24 of 36 meals)
- [ ] Seeded HPB table for Singapore dishes (user confirmed 2026-09-22)

## Key Decisions Made

- **No take-the-first-hit helper.** Searching "hainanese chicken rice" returns
  five confident wrong answers led by "Chicken curry with rice". Picking one is
  a language judgement, so `search` returns candidates and the model chooses.
  This makes the HPB seed more important, not less: local dishes do not merely
  miss, they mismatch.
- **Never send `dataType`.** `dataType=Survey (FNDDS)` answers HTTP 400 from
  nginx about three times in five, measured over ten probes per variant. Only
  the value with parentheses flaps. The dataset filter runs on the device off a
  wider page.
- **Tests live in the iOS suite, not `DexterMacTests`.** Any Mac test run boots
  a real instance against the live store and runs the trip cover reaper.
- **Extra latency on the composer is authorised** by the user (2026-09-22). The
  Shortcut path keeps its one-shot call under the 22 s ceiling.

## Context for Next Session

- The key is in `server/.env` (gitignored) and was pasted with a LEADING SPACE,
  which api.data.gov rejects as `API_KEY_INVALID` with no hint about
  whitespace. `ship-lan.sh` now trims it.
- `MealToolSchema` is the single statement of the estimate rules for three
  paths. Provenance fields must go in `itemSchema` there, not in a second copy.
- `MealEstimateGuards.check` is the only grader all paths meet. Derived
  confidence belongs there or beside it, not in the prompt.
