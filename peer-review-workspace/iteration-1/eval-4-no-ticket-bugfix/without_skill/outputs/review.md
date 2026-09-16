# PR #1412 Review: fix: technician availability showing wrong times for EST users

## Summary

This PR replaces a hardcoded UTC-5 offset with proper `zoneinfo.ZoneInfo` handling across the scheduling availability pipeline. The intent is correct and the overall direction is good. However, there are a few bugs (one potentially serious), missing error handling, and test gaps worth addressing before merging.

---

## Issues

### Bug: Naive datetime + `astimezone` produces wrong-day business hours

**Severity: High** | `src/scheduling/availability.py` lines near the `get_available_slots` method

When `date_str` is a date-only string like `"2025-03-09"`, `datetime.fromisoformat("2025-03-09")` produces a **naive** datetime at midnight: `datetime(2025, 3, 9, 0, 0)`.

Inside `business_hours_range`, this naive datetime hits `date.astimezone(tz)`. Python's `astimezone()` on a naive datetime assumes the **system local timezone**, not the user's timezone. If the server runs in UTC, midnight UTC converted to `America/New_York` becomes **March 8 at 7pm ET**. The subsequent `replace(hour=8)` then produces **March 8, 8am ET** -- the wrong day entirely.

This means a request for March 9's availability could return March 8's business hours depending on the server's system timezone.

**Suggested fix:** Parse `date_str` as a date, then construct the business-hours datetimes directly in the target timezone rather than converting a naive midnight:

```python
from datetime import date as date_type

d = date_type.fromisoformat(date_str)  # just a date, no time
biz_start = datetime(d.year, d.month, d.day, 8, 0, tzinfo=tz)
biz_end = datetime(d.year, d.month, d.day, 17, 0, tzinfo=tz)
```

Or, if full datetime strings are also valid inputs, detect and handle both cases.

### Bug: `to_utc` silently uses system timezone for naive datetimes when `tz` is None

**Severity: Medium** | `src/scheduling/time_utils.py`

```python
def to_utc(dt: datetime, tz: ZoneInfo | None = None) -> datetime:
    if dt.tzinfo is None and tz:
        dt = dt.replace(tzinfo=tz)
    return dt.astimezone(timezone.utc)
```

If `dt` is naive and `tz` is `None`, the function falls through to `dt.astimezone(timezone.utc)`, which silently assumes the system's local timezone. This is a footgun for future callers. It should either raise a `ValueError` for naive datetimes without a `tz`, or document the behavior explicitly.

### Missing error handling on user-supplied inputs

**Severity: Medium** | `src/scheduling/routes.py`, `src/scheduling/availability.py`

Neither `tz_name` nor `date_str` are validated:
- An invalid timezone (e.g., `tz="Foo/Bar"`) will raise an unhandled `KeyError` from `ZoneInfo`, resulting in a 500 instead of a 400.
- A malformed date (e.g., `date="not-a-date"`) will raise an unhandled `ValueError` from `fromisoformat`.

Add try/except with appropriate HTTP 400 responses, or use Pydantic/FastAPI validation.

### Dead import

**Severity: Low** | `src/scheduling/time_utils.py`

`time` is imported from `datetime` but never used in the file:

```python
from datetime import datetime, timedelta, timezone, time
```

Remove the `time` import.

### Undocumented API response shape change

**Severity: Low** | `src/scheduling/availability.py`

The response now includes `local_start` and `local_end` fields in each slot dict. This is a useful addition, but it is an API contract change not mentioned in the PR description. If there are consumers of this endpoint, they should be aware. Worth noting in the PR summary.

---

## Test Gaps

### DST test does not verify actual times

`test_dst_spring_forward` only checks `len(slots) == 9`. The original bug was about **wrong times**, not wrong slot count. The test should assert the actual start/end times of at least the first and last slots to confirm they represent 8am-5pm EDT (not EST) on March 9:

```python
# 8am EDT = 12:00 UTC (UTC-4, not UTC-5)
assert "12:00:00" in slots[0]["start"]
assert "21:00:00" in slots[-1]["end"]
```

Without this, the test would pass even if the times were still off by an hour.

### No test for the wrong-day bug

Given the naive-datetime issue described above, there should be a test that passes a date-only string and verifies that business hours land on the correct calendar date in the target timezone.

### No test with existing appointments

Both new tests use an empty appointment list. There is no new test verifying that overlap detection works correctly when appointment times span a DST boundary. Consider a test with an appointment booked in UTC that straddles the DST transition.

---

## Nits

- **`get_user_tz` is a trivial wrapper** that adds no validation, caching, or error handling over raw `ZoneInfo(tz_name)`. Consider either adding value (validation, friendly error message) or inlining the call.
- The variable rename from `is_free` to `overlaps` (with inverted logic) is fine but is a style change unrelated to the bug fix. Not a problem, just noting it as a separate concern mixed into a bugfix PR.
- The `tz` query parameter in the route could benefit from a regex or enum constraint to reject obviously invalid values at the FastAPI layer.

---

## What Looks Good

- Correct decision to use `zoneinfo.ZoneInfo` over fixed offsets -- this is the right long-term approach.
- The `to_utc` handling for naive datetimes (attaching timezone before converting) is a reasonable pattern when `tz` is provided.
- Adding `local_start`/`local_end` to the response is genuinely useful for clients that need to display local times.
- Test coverage for multiple timezones (ET and PT) is a good start.

---

## Verdict

**Request changes.** The naive-datetime-to-wrong-day bug is a real correctness issue that could ship a regression in production. The missing input validation would cause 500s on bad input. Both should be fixed before merge. The test gaps are important to close, especially verifying actual slot times rather than just counts.
