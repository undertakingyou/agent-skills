## Peer Review: DEMO-303 / PR #1105

**Ticket**: Implement equipment search with filters
**PR**: feat: equipment search endpoint with filters
**Scope**: 5 files changed, +245/-0 lines

---

### Ticket Fulfillment

| # | Requirement | Status | Notes |
|---|-------------|--------|-------|
| 1 | Search endpoint at `/api/v1/equipment/search` with full-text search on equipment name and model number | Met | `routes.py` adds `@router.post("/search")` under the `/api/v1/equipment` prefix. `repository.py` uses `ilike` on both `Equipment.name` and `Equipment.model_number`. |
| 2 | Filter by equipment type | Met | `repository.py` filters on `Equipment.equipment_type` when provided. |
| 3 | Filter by manufacturer | Met | `repository.py` filters on `Equipment.manufacturer` when provided. |
| 4 | Filter by installation date range | Unmet | No date range fields exist in `EquipmentSearchRequest` or `repository.search()`. The `date` import in `schemas.py` is unused, suggesting this was planned but not implemented. |
| 5 | Filter by active/inactive status | Met | `repository.py` correctly checks `is_active is not None` before filtering, so `False` is handled properly. |
| 6 | Cursor-based pagination (default 25 per page) | Partial | Default 25/page is correct (`schemas.py` Field default). However, the implementation uses offset-based pagination (`page`/`page_size` with `q.offset().limit()` in `repository.py`), not cursor-based as the ticket specifies. The PR description acknowledges this: "Pagination uses offset-based approach for now." |
| 7 | Include total count in response metadata | Partial | The total is computed in `repository.py` via `q.count()`, but `PaginationMeta` in `schemas.py` only exposes `total_pages`, not the raw `total_count`. A consumer needing "showing X of Y results" cannot derive the exact count from the response. |
| 8 | Case-insensitive search | Met | `repository.py` uses `ilike` for both name and model number matching. |
| 9 | Empty search with no filters returns all equipment for tenant, paginated | Met | All filter parameters are optional with `None` defaults. The base query returns all tenant equipment, paginated. Covered by `test_empty_search_returns_all`. |

**Overall**: 5 of 9 requirements fully met, 2 partially met, 1 unmet. The installation date range filter is missing entirely, pagination deviates from the specified cursor-based approach, and `total_count` is absent from the response metadata.

---

### Highlights

- **Proper tenant isolation and soft-delete awareness** (`repository.py`): The `search` method correctly scopes every query by `tenant_id` and filters out soft-deleted records with `Equipment.deleted_at.is_(None)`. This is easy to forget on a new query method, and getting it right from the start prevents a class of data-leak bugs.

- **Thoughtful request validation** (`schemas.py`): `EquipmentSearchRequest` uses Pydantic `Field` constraints to enforce `page >= 1` and `1 <= page_size <= 100`. This prevents nonsensical inputs (page 0, negative page sizes, absurdly large pages) at the validation layer before they reach the database.

- **Clean layered architecture** (all files): The route handler is a thin orchestrator that delegates to the service, which delegates to the repository. Each layer has a clear responsibility. The service constructs the response schema, the repository owns the query, and the route handles HTTP concerns. This separation will make the code straightforward to test and extend.

- **Correct `is_active` filter guard** (`repository.py`): Using `if is_active is not None` rather than the more common `if is_active` correctly handles the `is_active=False` case. A truthiness check would silently skip the filter when searching for inactive equipment.

---

### Findings

- **Important** -- LIKE wildcard injection in `repository.py`: The search term is constructed as `f"%{query}%"` (line 69) without escaping LIKE-special characters (`%` and `_`). A user searching for the literal string `%` or `100%` will get unintended wildcard expansion, returning far more results than expected. SQLAlchemy parameterizes the value (so this is not SQL injection), but it produces incorrect search behavior. Fix: escape `%` and `_` in the query before wrapping with wildcards, e.g., `query.replace('%', r'\%').replace('_', r'\_')` with the appropriate `escape` clause on `ilike`.

- **Important** -- No ORDER BY on search results (`repository.py`): The query has no explicit ordering. Without a deterministic `ORDER BY`, the database may return rows in any order, which means paginated results are non-deterministic -- a row could appear on multiple pages or be skipped entirely between page requests. This is especially problematic combined with offset-based pagination. Fix: add `.order_by(Equipment.name)` or another stable sort key.

- **Important** -- `EquipmentOutput.model_validate(r)` may fail at runtime (`service.py`, line ~27): `model_validate()` is called on SQLAlchemy ORM model instances. For this to work, `EquipmentOutput` must have `model_config = ConfigDict(from_attributes=True)` (Pydantic v2) or `class Config: orm_mode = True` (Pydantic v1). The diff does not show this configuration on `EquipmentOutput`, and the existing schema definition in the diff does not include it. If it is not already present in the existing code, this will raise a `ValidationError` at runtime for every search request.

- **Important** -- Installation date range filter missing (`schemas.py`, `repository.py`): The ticket explicitly requires filtering by installation date range, but no `install_date_from` or `install_date_to` fields exist in the request schema or the repository query. The unused `from datetime import date` in `schemas.py` suggests this was planned. This is a gap that should be addressed before the ticket can be considered complete.

- **Minor** -- Response metadata missing `total_count` (`schemas.py`): The ticket requires "total count in response metadata." `PaginationMeta` provides `total_pages` but not the raw `total_count`. While `total_pages` is useful, the actual count is needed for UIs that show "X results found." Adding a `total_count: int` field to `PaginationMeta` would satisfy the requirement precisely.

- **Minor** -- Unused imports (`schemas.py`, `repository.py`): `Any` (from `typing`) and `date` (from `datetime`) are imported in `schemas.py` but never used. `func` is imported from `sqlalchemy` in `repository.py` but never used. These are cleanup items.

- **Minor** -- Count and data queries are not atomic (`repository.py`): `q.count()` and `q.offset().limit().all()` execute as two separate database queries. Under concurrent writes, the count could reflect a different state than the results. For a search endpoint this is typically acceptable, but it is worth being aware of -- a user could see "75 results" in metadata but only be able to page through 74.

---

### What I Verified

- Traced the tenant scoping in `repository.search()` -- `tenant_id` is applied as the first filter on the base query, ensuring no cross-tenant data leakage.
- Confirmed soft-delete filtering (`deleted_at.is_(None)`) is applied to the search query, consistent with the existing `get_all_for_tenant` method.
- Verified the `is_active` filter uses `is not None` rather than truthiness, so `is_active=False` correctly filters for inactive equipment rather than being silently skipped.
- Checked Pydantic field constraints: `page` has `ge=1`, `page_size` has `ge=1, le=100` -- these prevent zero/negative pagination values and limit maximum page size.
- Verified the `total_pages` calculation handles the zero-results edge case (`if total > 0 else 1`), avoiding division-by-zero.
- Confirmed the route correctly extracts `tenant_id` from `get_current_tenant` dependency rather than accepting it from the request body (preventing tenant spoofing).
- Checked for ticket numbers in code comments or docstrings in the diff additions -- none found.
- Confirmed no cross-subproject imports: all imports are within `src/equipment/` or from `src/auth/dependencies` (a shared auth module, which is appropriate).

---

### Summary

The PR establishes a well-structured equipment search endpoint with clean layering, proper tenant isolation, and solid request validation. However, three substantive gaps prevent full ticket fulfillment: the installation date range filter is missing entirely, pagination uses offset-based rather than the specified cursor-based approach, and `total_count` is absent from the response. On the code quality side, the missing `ORDER BY` and unescaped LIKE wildcards are the most impactful issues -- both can produce incorrect results in production. I would request changes to address the missing date range filter, add a deterministic sort order, and escape LIKE special characters before approving.
