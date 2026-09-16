# Peer Review: PR #1105 - feat: equipment search endpoint with filters

**Ticket:** DEMO-303 - Implement equipment search with filters
**Branch:** feat/equipment-search -> main

---

## Summary

This PR adds an equipment search endpoint at `/api/v1/equipment/search` with text search and filtering by type, manufacturer, and active status. The implementation is cleanly structured across routes, service, repository, and schema layers with supporting unit tests. However, several ticket requirements are missing or deviated from.

---

## Missing Ticket Requirements

### 1. Installation date range filter is not implemented

The ticket explicitly requires filtering by "installation date range." This filter is entirely absent from `EquipmentSearchRequest`, the repository `search` method, and the service layer. Notably, the diff imports `from datetime import date` in `schemas.py` but never uses it, suggesting the author started on this and dropped it. This is a clear gap against the acceptance criteria.

### 2. Cursor-based pagination was replaced with offset-based pagination

The ticket specifies "cursor-based pagination." The PR implements offset-based pagination (page number + page size) instead. The PR description acknowledges this: "Pagination uses offset-based approach for now." While offset pagination is simpler, cursor-based pagination was an explicit requirement, likely chosen for performance on large datasets (offset pagination degrades as page numbers grow because the database must scan and discard rows). If this is a deliberate deferral, it should be discussed and tracked as a follow-up ticket, not silently shipped as a deviation.

### 3. Total count is missing from response metadata

The ticket says "Include total count in response metadata." The `PaginationMeta` schema includes `page`, `page_size`, and `total_pages` but not `total_count`. The total is calculated in the repository (the `total` variable) and used to derive `total_pages`, but the raw count is never exposed. Clients often need the total count for UI display (e.g., "Showing 1-25 of 312 results"). This is a straightforward addition: add `total_count: int` to `PaginationMeta` and pass it through from the service layer.

---

## Bugs and Issues

### Unused imports

- `schemas.py` imports `Any` from `typing` -- never used.
- `schemas.py` imports `date` from `datetime` -- never used (artifact of the missing date range filter).
- `routes.py` imports `Query` from `fastapi` -- never used (the endpoint uses a request body, not query parameters).

These should be cleaned up. Linters will flag them, and they create confusion about intent.

### LIKE wildcard injection in search term

In `repository.py`, the search term is built as:

```python
search_term = f"%{query}%"
```

If a user passes `%` or `_` in their query string, those are LIKE/ILIKE wildcard characters and will produce unexpected matching behavior. For example, searching for `100%` would match any string containing `100` followed by anything. The fix is to escape these characters before wrapping in `%`:

```python
escaped = query.replace("%", "\\%").replace("_", "\\_")
search_term = f"%{escaped}%"
```

### Potential ORM-to-Pydantic serialization issue

In `service.py`, the code does:

```python
data=[EquipmentOutput.model_validate(r) for r in results]
```

This calls `model_validate` on SQLAlchemy model instances. For this to work, `EquipmentOutput` must have `model_config = ConfigDict(from_attributes=True)` set. The existing `EquipmentOutput` class in the diff does not show this configuration. If it is not set elsewhere, this will raise a `ValidationError` at runtime. Verify this is configured; if not, add it.

### manufacturer and equipment_type filters are case-sensitive

The text search correctly uses `ilike` for case-insensitive matching, but the `equipment_type` and `manufacturer` filters use exact equality (`==`). If the data has inconsistent casing (e.g., "HVAC" vs "hvac"), filters will silently miss results. Confirm whether the data is normalized on write; if not, consider using `ilike` or `.lower()` for these filters as well.

---

## Testing Gaps

- **No repository-layer tests.** The SQL query construction logic in `repository.search` is the most complex and bug-prone part of this PR, but it is not tested. The unit tests mock the repository entirely, so they only verify that the service passes arguments through. A repository integration test against a test database would catch SQL construction bugs.
- **No route-layer tests.** There are no tests verifying the HTTP contract: correct status codes, request validation (e.g., page < 1 rejected), content type, auth enforcement.
- **The PR description says "Integration tests"** but the tests are unit tests with `MagicMock`. This is a mismatch worth calling out.
- **No test for the edge case where `page_size` divides `total` evenly** (e.g., total=50, page_size=25 should give total_pages=2, not 3).
- **No test for zero results** (empty data list with appropriate metadata).

---

## What's Good

- **Clean layering.** Routes, service, repository, and schemas are well-separated. The dependency injection pattern with FastAPI's `Depends` is used correctly.
- **Tenant scoping.** All queries are scoped to `tenant_id` and filter out soft-deleted records (`deleted_at.is_(None)`), which is correct for a multi-tenant system.
- **Sensible defaults.** Page size defaults to 25 as the ticket requires, with a max of 100 enforced via Pydantic's `Field(le=100)`.
- **The `is_active` filter correctly uses `is not None`** rather than a truthiness check, so `is_active=False` works as intended.

---

## Verdict

The PR delivers a solid foundation for equipment search, but it is **not ready to merge** as-is against the DEMO-303 requirements. Three ticket requirements are unmet (date range filter, cursor-based pagination, total count), and there is a minor bug with LIKE wildcard characters. The author should either implement the missing requirements or explicitly agree with the team to defer them to tracked follow-up tickets before this merges.
