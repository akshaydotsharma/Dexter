# Ground meal estimates in real food data (#653)

**Status**: complete — PR #654 open, awaiting device QA
**Started**: 2026-09-22
**Last Updated**: 2026-09-22 03:30 SGT
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

- [ ] Device QA. The build is on the phone (`C2241792`, 2026-09-22 03:26). Log a
      real meal through the composer and check the preview shows sourced
      composition and a portion that is not a guess.

## Next Steps

- [ ] Merge #654 once QA passes
- [ ] Consider: chat and the Shortcut still have no lookups, so their estimates
      fall back to the model's own band. Converting chat is the obvious next
      step; the Shortcut's 22 s ceiling makes it a real design question.

## Completed

- [x] All seven scope items on #653. Four commits, PR #654.
- [x] `d8963b7` FoodData Central client
- [x] `5959dac` lookup tool, provenance, ledger, derived band
- [x] `0bd4cc5` saved library and past portions
- [x] `7f781c7` the 2,689-dish Singapore table

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
