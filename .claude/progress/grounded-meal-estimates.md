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
- [x] Raise #653 (2026-09-22)
- [x] `USDA_FDC_API_KEY` through the whole build chain; Mac signature verified
      still valid with three keys injected (2026-09-22)
- [x] `FoodDataCentralClient` + 31 tests — commit `d8963b7`
- [x] Batched `look_up_foods` tool, per-item provenance, ledger verification,
      device-side recompute, derived confidence — commit `5959dac`
- [x] `statedQuantities(in:)`, after a live run showed the model reporting a
      user-stated 250 g as a guess — in `5959dac`
- [x] Saved library as a lookup source, and past portions as a mass source —
      commit `0bd4cc5`
- [x] Found the real HPB endpoint. The old `focos.hpb.gov.sg` host is GONE
      (NXDOMAIN); the service is now the Singapore Food Insights Database at
      `pphtpc.hpb.gov.sg/bff/v1/food-portal` (2026-09-22)

## Current Step

- [ ] Ship the Singapore table
  - [x] `build-sg-food-table.py` — enumerates by substring search, reads
        details, caches, backs off on 429
  - [x] `SGFoodTable.swift` + tests, wired as a lookup source between the
        library and FoodData Central
  - [ ] The crawl itself (running; ~2,400 dishes at 2 requests/second)
  - [ ] Add the JSON to the resources list for BOTH targets and run the tests
        that assert the asset is actually in the bundle

## Next Steps

- [ ] Open the PR
- [ ] Ship to phone and let the user QA a real meal

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
