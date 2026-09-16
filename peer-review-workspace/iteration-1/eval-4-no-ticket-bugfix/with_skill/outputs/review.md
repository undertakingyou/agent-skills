## Peer Review: PR #1412

**PR**: fix: technician availability showing wrong times for EST users
**Scope**: 4 files changed, +66/-23 lines

---

### Highlights

- **Root-cause fix, not a patch** (`time_utils.py`): Rather than adding a DST toggle or special-casing Eastern time, the PR replaces the fundamentally broken `EST_OFFSET = timezone(timedelta(hours=-5))` with `zoneinfo.ZoneInfo`, which is the stdlib's correct abstraction for DST-aware timezones. This eliminates the entire class of fixed-offset bugs, not just the reported one.

- **Timezone threading makes the system multi-timezone by design** (`availability.py`, `routes.py`): By parameterizing `tz_name` all the way from the route through the service and into `time_utils`, the fix doesn't just correct EST -- it makes the availability pipeline work for any IANA timezone. A Pacific or Central user gets correct business hours without further code changes. This turns a bugfix into a capability improvement.

- **Backward-compatible API extension with `local_start`/`local_end`** (`availability.py`): The slot response now includes both UTC times (`start`/`end`) and local times (`local_start`/`local_end`). This is additive -- existing consumers that read `start`/`end` are unaffected -- and it gives front-end clients the local representation without needing to re-derive it, reducing the risk of client-side timezone bugs.

- **Targeted regression tests for the exact failure mode** (`test_availability.py`): The `test_dst_spring_forward` test on March 9, 2025 directly exercises the DST boundary that caused the original bug. The `test_availability_respects_user_timezone` test goes further with a concrete UTC offset assertion (`15:00:00` for 8am Pacific in summer), verifying conversion math rather than just slot count.

---

### Findings

- **Critical -- `business_hours_range` silently produces wrong times on DST transition days** (`time_utils.py:business_hours_range`): The function calls `date.astimezone(tz)` to get `local_date`, then does `local_date.replace(hour=8, ...)`. On March 9, 2025 (DST spring-forward), `local_date` will carry the UTC offset from the original time. When `.replace(hour=8)` is called, the `tzinfo` offset is **not recalculated** -- it retains the offset from the original time. If `local_date` was in EST (UTC-5) because the input was midnight, then `start` at "8:00" will carry UTC-5 even though 8am on that day is actually EDT (UTC-4). This means all downstream slot times will be shifted by one hour on DST transition days -- **the exact class of bug this PR intends to fix**. The correct approach is to strip tzinfo after `.replace()` and re-localize, forcing `ZoneInfo` to pick the correct offset for the target wall-clock time. The existing `test_dst_spring_forward` test only checks `len(slots) == 9` (which still passes because the window is still 9 hours), so it does not catch this.

- **Important -- `to_utc` silently produces wrong results for naive datetimes when `tz` is not passed** (`time_utils.py:to_utc`): When `dt` is naive and `tz` is `None` (or not passed), Python's `.astimezone()` on a naive datetime assumes the system's local timezone. This is environment-dependent behavior that will produce different results on different servers. Any future caller that does `to_utc(some_naive_dt)` without passing `tz` will get silently wrong results. Recommendation: either require `tz` (drop the `None` default) or raise a `ValueError` when `dt.tzinfo is None and tz is None` instead of falling through silently.

- **Important -- `get_user_tz` does not handle invalid timezone names** (`time_utils.py:get_user_tz`): `ZoneInfo("Not/A/Timezone")` raises `KeyError`, which will bubble up as an unhandled 500 from the route layer. There's no validation at the route level either -- the `tz` query parameter is a bare string. Any API consumer passing a typo or invalid timezone string gets an opaque internal server error instead of a 400/422 with a useful message. Recommendation: catch `KeyError` and raise a domain-appropriate exception, or add validation at the route layer.

- **Important -- `datetime.fromisoformat` with a bare date string produces a naive midnight datetime** (`availability.py:get_available_slots`): When `date_str` is `"2025-03-09"` (date without time), `fromisoformat` returns `datetime(2025, 3, 9, 0, 0)` -- a naive datetime at midnight. This is then passed to `business_hours_range(date, tz)`, which calls `date.astimezone(tz)`. As with `to_utc`, `.astimezone()` on a naive datetime assumes system-local time, making the result deployment-dependent. Recommendation: explicitly attach the timezone before passing to `business_hours_range`, e.g., `date = datetime.fromisoformat(date_str).replace(tzinfo=tz)`.

- **Important -- Breaking change to `get_available_slots` method signature** (`availability.py`): The method signature changed from `date: datetime` to `date_str: str, tz_name: str`. This is a breaking change for any existing callers beyond the route. If there are other callers (background jobs, internal services, other routes), they will break at runtime with a `TypeError`. Cannot fully assess without seeing all callers, but this is the kind of change that breaks things without test coverage.

- **Minor -- Unused import `time`** (`time_utils.py`): The diff adds `from datetime import datetime, timedelta, timezone, time` but `time` is never used in the new code. This will trigger linting warnings.

- **Minor -- `test_dst_spring_forward` doesn't verify correct times** (`test_availability.py`): The test only asserts `len(slots) == 9`. It does not check that the slots are at the correct times (8am-5pm EDT, not shifted). Given the `business_hours_range` issue above, this test would pass even with incorrect times. A stronger test would verify the UTC times or offsets of the first/last slot, similar to how `test_availability_respects_user_timezone` asserts `"15:00:00"`.

---

### What I Verified

- **Overlap detection logic is correct**: The refactor from `is_free = not any(...)` to `overlaps = any(...)` / `if not overlaps:` is a pure readability rename -- the boolean logic is identical. Traced through: `any(s < slot_end and e > current)` correctly detects overlap for all cases (partial overlap start, partial overlap end, full containment, exact boundary).

- **Slot iteration logic is unchanged and correct**: The `while current + timedelta(minutes=slot_duration_minutes) <= biz_end` loop and `current = slot_end` advancement are not modified and correctly generate non-overlapping contiguous slots covering the full business hours window.

- **`to_local` is straightforward and correct**: `dt.astimezone(tz)` on an aware datetime correctly converts to the target timezone. No edge case issues.

- **`to_utc` is correct for aware datetimes**: When `dt` already has `tzinfo`, the function correctly converts to UTC regardless of whether `tz` is passed. The issue only arises with naive datetimes.

- **No stale ticket references in code**: Scanned all additions in the diff -- no ticket numbers (`WKD-`, `EQD-`, `INTAPI-`, `TODO(`, etc.) appear in code comments or docstrings.

- **No cross-subproject coupling introduced**: All imports stay within `src/scheduling/`. The route correctly delegates to the service layer. No direct database access from the route.

- **New `local_start`/`local_end` fields are additive and backward-compatible**: These are new keys added to the response dict alongside the existing `start`/`end` UTC fields. Existing consumers that only read `start`/`end` are unaffected.

- **Test fixtures use proper mocking pattern**: Both new tests use `mock_repo.get_appointments.return_value = []` consistently with the existing test structure.

---

### Summary

This PR makes the right architectural move -- replacing a hardcoded UTC-5 offset with `zoneinfo.ZoneInfo` and threading timezone awareness through the full pipeline. However, the `business_hours_range` function has a critical bug: `.replace(hour=8)` on a timezone-aware datetime does not recalculate the UTC offset, which means slot times will still be wrong on DST transition days -- the exact failure mode this PR aims to fix. The DST test doesn't catch it because it only checks slot count, not actual times. I'd request changes to fix the `.replace()` re-localization issue, strengthen the DST test to assert correct UTC times, and add input validation for the timezone parameter.
