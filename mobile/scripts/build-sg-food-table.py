#!/usr/bin/env python3
"""Build the Singapore food composition table shipped with Dexter (#653).

Reads the Health Promotion Board's Singapore Food Insights Database (formerly
FOCOS "Energy & Nutrient Composition of Food") and writes a single JSON asset
the app loads on device.

WHY A SHIPPED TABLE AND NOT A LIVE CALL
---------------------------------------
USDA FoodData Central does not hold Singapore food, and the way it fails is the
dangerous way: searching "hainanese chicken rice" there returns five confident
wrong answers led by "Chicken curry with rice". HPB holds the real dishes, with
a real local serving weight and, for many rows, laboratory analysis rather than
a survey average.

The data is static, the whole set is about two thousand rows, and the lookup has
to work with no network and no key. So it is read ONCE, here, and shipped.

POLITENESS
----------
This is a one-time build step against a public government service, not something
the app does. It is rate limited, single-purpose, read-only, and identifies
itself. Re-run it only when refreshing the table.

USAGE
-----
    python3 mobile/scripts/build-sg-food-table.py \
        --out mobile/PersonalDashboard/Resources/sg-food-table.json

    --limit N   stop after N dishes (for a smoke run)
"""

from __future__ import annotations

import argparse
import json
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path

BASE = "https://pphtpc.hpb.gov.sg/bff/v1/food-portal"
UA = "Dexter/1.0 (personal food log; one-time table build; github.com/akshaydotsharma/Dexter)"

# Enumeration is by substring search: there is no "list everything" endpoint.
# Vowels cover essentially every name; the consonants catch the handful that a
# vowel misses (abbreviations, transliterations).
SEED_TERMS = list("aeiou") + list("bcdfghjklmnpqrstvwxyz")

PAGE_SIZE = 25

# MEASURED. 0.12 s between requests (about 8/s) earns HTTP 429 after roughly
# 2,300 requests. 0.5 s has run the full build without one. The service is a
# public good being read for a personal app; the right pace is the one that
# never makes anybody notice.
THROTTLE = 0.5
RETRIES = 5

# Responses are cached on disk so a re-run, or a run interrupted by a 429,
# costs nothing for what it already has. A refresh deletes the directory.
CACHE = Path(".sg-food-cache")


def fetch(path: str, cache_key: str | None = None, **params) -> object:
    """One GET, cached, retried, and backed off politely on 429."""
    cached = CACHE / f"{cache_key}.json" if cache_key else None
    if cached and cached.exists():
        try:
            return json.loads(cached.read_text(encoding="utf-8"))
        except json.JSONDecodeError:
            cached.unlink()

    url = BASE + path + ("?" + urllib.parse.urlencode(params) if params else "")
    last = None
    for attempt in range(RETRIES):
        try:
            req = urllib.request.Request(
                url, headers={"User-Agent": UA, "Accept": "application/json"}
            )
            with urllib.request.urlopen(req, timeout=30) as resp:
                body = json.load(resp)
            if cached:
                cached.parent.mkdir(parents=True, exist_ok=True)
                cached.write_text(json.dumps(body), encoding="utf-8")
            return body
        except urllib.error.HTTPError as err:
            if err.code == 400:            # "Food not found" is a real answer
                return None
            last = err
            if err.code == 429:
                # Honour Retry-After when it is offered; otherwise back off hard.
                wait = err.headers.get("Retry-After")
                pause = float(wait) if wait and wait.isdigit() else 15.0 * (attempt + 1)
                print(f"    429 — waiting {pause:.0f}s", flush=True)
                time.sleep(pause)
                continue
        except Exception as err:           # noqa: BLE001 - transient network
            last = err
        time.sleep(1.5 * (attempt + 1))
    raise RuntimeError(f"{url} failed after {RETRIES} attempts: {last}")


def enumerate_ids(verbose: bool = True) -> dict[str, dict]:
    """Every crId the search will admit, with its search-row summary."""
    found: dict[str, dict] = {}
    for term in SEED_TERMS:
        page = 1
        before = len(found)
        while True:
            rows = fetch("/foods", cache_key=f"search/{term}-{page}",
                         searchText=term, pageNumber=page) or []
            if not rows:
                break
            for row in rows:
                if row.get("isDeactivated"):
                    continue
                found.setdefault(row["crId"], row)
            total = rows[0].get("totalCount", 0)
            if page * PAGE_SIZE >= total:
                break
            page += 1
            time.sleep(THROTTLE)
        if verbose:
            print(f"  '{term}': +{len(found) - before:<5} total {len(found)}", flush=True)
        time.sleep(THROTTLE)
    return found


# HPB uses -1 for "not analysed" and null for "not applicable". Reading either
# as a number is the same class of error as reading Open Food Facts' sodium in
# grams as milligrams: it produces a plausible figure nothing downstream can
# question. A missing nutrient is recorded as missing, never as zero.
def value(raw) -> float | None:
    if raw is None:
        return None
    try:
        number = float(raw)
    except (TypeError, ValueError):
        return None
    return None if number < 0 else number


NUTRIENT_KEYS = {
    "calories": "energy",
    "proteinG": "protein",
    "carbsG": "carbohydrate",
    "fatG": "fat",
    "fibreG": "dietaryFibre",
    "sugarG": "sugar",
    "sodiumMg": "sodium",
    "satFatG": "saturatedFat",
}


def entry(detail: dict) -> dict | None:
    base = detail.get("baseFoodNutrients") or {}
    per100: dict[str, float] = {}
    missing: list[str] = []
    for ours, theirs in NUTRIENT_KEYS.items():
        v = value(base.get(theirs))
        if v is None:
            missing.append(ours)
            per100[ours] = 0.0
        else:
            per100[ours] = round(v, 3)

    # A row with no energy is not a food record worth shipping.
    if "calories" in missing:
        return None

    out = {
        "id": detail["crId"],
        "name": detail.get("name", "").strip(),
        "description": (detail.get("description") or "").strip(),
        "category": detail.get("l1Category") or "",
        "subCategory": detail.get("l2Category") or "",
        "source": detail.get("sourceOfData") or "",
        "year": detail.get("yearOfData"),
        "per100": per100,
    }
    if missing:
        out["missing"] = missing

    weight = value(detail.get("defaultWeight"))
    if weight:
        out["portionGrams"] = round(weight, 1)
        label = (detail.get("defaultPortion") or "").strip()
        if label and label != "-":
            out["portionLabel"] = label
    return out


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--out", required=True, type=Path)
    parser.add_argument("--limit", type=int, default=0)
    args = parser.parse_args()

    print("enumerating…", flush=True)
    rows = enumerate_ids()
    ids = sorted(rows)
    if args.limit:
        ids = ids[: args.limit]
    print(f"{len(ids)} dishes to read", flush=True)

    entries, skipped = [], 0
    for index, crid in enumerate(ids, 1):
        detail = fetch(f"/foods/details/{crid}", cache_key=f"detail/{crid}")
        if detail:
            built = entry(detail)
            if built:
                entries.append(built)
            else:
                skipped += 1
        else:
            skipped += 1
        if index % 100 == 0:
            print(f"  {index}/{len(ids)} ({skipped} skipped)", flush=True)
        time.sleep(THROTTLE)

    payload = {
        "source": "Health Promotion Board, Singapore Food Insights Database",
        "sourceURL": "https://www.hpb.gov.sg/healthy-living/food-and-beverage/sgfoodid/",
        "retrieved": time.strftime("%Y-%m-%d"),
        "note": (
            "Per 100 g of edible portion. Sodium in mg, energy in kcal, the rest in "
            "grams. 'missing' names nutrients the record did not carry; those read 0 "
            "and must not be treated as measured zeroes."
        ),
        "entries": entries,
    }

    args.out.parent.mkdir(parents=True, exist_ok=True)
    # Sorted keys and a fixed separator so a re-run that changes nothing produces
    # a byte-identical file and an empty diff.
    args.out.write_text(
        json.dumps(payload, ensure_ascii=False, sort_keys=True, separators=(",", ":")),
        encoding="utf-8",
    )
    kb = args.out.stat().st_size / 1024
    print(f"wrote {len(entries)} entries, {skipped} skipped, {kb:.0f} KB -> {args.out}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
