# Peer Review: PR #542 - Bulk Archive Endpoint for Work Orders

**Ticket:** DEMO-101  
**Branch:** feat/bulk-archive-work-orders -> main

---

## Ticket Requirements Checklist

| Requirement | Status | Notes |
|---|---|---|
| POST endpoint at `/api/v1/work-orders/bulk-archive` | Met | Route correctly defined with proper prefix |
| Validate IDs belong to requesting tenant | Met | `get_current_tenant` dependency + repo filters by `tenant_id` |
| Only archive `completed` or `cancelled` status | Met | `ARCHIVABLE_STATUSES` set checked in service |
| Return summary response `{archived, failed}` | Met | `BulkArchiveResponse` schema matches spec |
| Audit log entry for each archived work order | Met | `audit_service.log()` called per archived WO |
| Batch size limit of 100 | Met | Enforced (with caveats, see below) |

All six ticket requirements are addressed.

---

## Bugs

### 1. `get_logger` is not imported (service.py)

The service adds `self._logger = get_logger(__name__)` but the diff does not import `get_logger`. This will raise a `NameError` at class instantiation time, making the entire endpoint non-functional.

```python
self._logger = get_logger(__name__)  # get_logger is never imported
```

### 2. Type mismatch between service and repository (repository.py)

The repository method signature declares `work_order_ids: list[str]`, but the service passes `List[UUID]` values. The `IN` clause may still work depending on the ORM/database driver coercion, but the type annotation is wrong and this could cause subtle bugs with different database backends.

```python
# repository.py - declares str
def get_by_ids(self, work_order_ids: list[str], tenant_id: str) -> list[WorkOrder]:

# service.py - passes UUID
work_orders = self.repository.get_by_ids(work_order_ids, tenant_id)
```

Should be `list[UUID]` in the repository signature.

---

## Issues

### 3. Duplicate batch size validation (routes.py + schemas.py)

The 100-item limit is enforced in two places:
- **Schema:** `Field(..., max_length=100)` on the Pydantic model -- this triggers a **422** validation error
- **Route handler:** `if len(request.work_order_ids) > 100` -- this raises a **400** HTTPException

The Pydantic validation runs first, so the route-level check is dead code. The 400 will never be reached. Pick one enforcement point. If you want a 400, remove the schema constraint and keep the route check. If 422 is acceptable, remove the route check.

### 4. `datetime.utcnow()` is deprecated (repository.py)

`datetime.utcnow()` has been deprecated since Python 3.12. Use `datetime.now(datetime.UTC)` or `datetime.now(timezone.utc)` instead. Also, `datetime` does not appear to be imported in the repository diff -- confirm it exists in the existing file.

```python
wo.archived_at = datetime.utcnow()  # deprecated
```

### 5. No minimum list length validation (schemas.py)

An empty list `{"work_order_ids": []}` passes validation and returns `{"archived": [], "failed": []}`. This is a wasted round-trip. Consider adding `min_length=1` (or `min_items=1` depending on Pydantic version) to the schema field.

### 6. No duplicate ID handling

If a caller sends the same UUID twice, the `set()` operations in the service will deduplicate silently. The endpoint will appear to succeed but the count of archived IDs won't match the count of submitted IDs, which could confuse callers. Consider either rejecting duplicates with a validation error or documenting the deduplication behavior.

### 7. Atomicity between archive and audit logging

`repository.bulk_archive()` calls `session.flush()` and then the service iterates to write audit logs. If audit logging raises an exception partway through, some audit entries will exist and others won't, while the work order status changes (flushed but uncommitted) would roll back. This leaves audit logs for work orders that were never actually archived. Consider whether audit logging should happen inside the same unit of work, or confirm that the audit service has its own error handling.

---

## Missing from PR description

The PR description mentions an **integration test hitting the endpoint with mixed valid/invalid IDs**, but the test file contains only unit tests using mocks. No integration test (e.g., using `TestClient` or `httpx.AsyncClient`) is present in the diff.

---

## What's Good

- **Clean layered architecture**: Routes, service, repository, and schemas are properly separated. Each layer has a clear responsibility.
- **Tenant isolation by default**: The repository query filters by `tenant_id`, so cross-tenant access is impossible at the data layer -- not just at the route level.
- **Soft-delete awareness**: The `deleted_at.is_(None)` filter in `get_by_ids` correctly excludes soft-deleted records.
- **Structured failure reporting**: The response cleanly separates successes from failures with reasons, which is good API design for batch operations.
- **Structured logging**: Warning log for not-found work orders with the ID included (once the import is fixed).
- **Good test coverage for the service layer**: Tests cover the main paths -- all valid, all invalid status, missing, mixed, and audit log verification.

---

## Summary

The PR fulfills all six ticket requirements. Two bugs need fixing before merge: the missing `get_logger` import (which would make the endpoint crash on startup) and the `str` vs `UUID` type mismatch in the repository. The dead-code batch validation and deprecated `datetime.utcnow()` are lower priority but worth addressing. The missing integration test mentioned in the PR description should either be added or the description updated.
