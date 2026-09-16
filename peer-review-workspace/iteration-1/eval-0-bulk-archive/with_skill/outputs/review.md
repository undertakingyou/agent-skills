## Peer Review: DEMO-101 / PR #542

**Ticket**: Add bulk archive endpoint for work orders
**PR**: feat: bulk archive endpoint for work orders
**Scope**: 5 files changed, +248/-2 lines

---

### Ticket Fulfillment

| # | Requirement | Status | Notes |
|---|-------------|--------|-------|
| 1 | POST endpoint at `/api/v1/work-orders/bulk-archive` accepting a list of work order IDs | Met | `routes.py` adds `@router.post("/bulk-archive")` on router with prefix `/api/v1/work-orders`. Request body is `BulkArchiveRequest` with `work_order_ids: List[UUID]` (`schemas.py`). |
| 2 | Validate all IDs belong to the requesting tenant | Met | `repository.py` `get_by_ids` filters by `tenant_id` directly in the query. IDs belonging to other tenants are returned as failures with reason "not found" in `service.py`. Tenant sourced via `Depends(get_current_tenant)` in the route. |
| 3 | Only archive `completed` or `cancelled` work orders; return errors for others | Met | `service.py` defines `ARCHIVABLE_STATUSES = {"completed", "cancelled"}` and separates archivable from non-archivable, appending failures with a status-based reason message. |
| 4 | Return summary response `{"archived": [...], "failed": [{"id": ..., "reason": ...}]}` | Met | `schemas.py` defines `BulkArchiveResponse` with `archived: List[UUID]` and `failed: List[ArchiveFailure]` (id + reason). Route declares `response_model=BulkArchiveResponse`. |
| 5 | Audit log entry for each successfully archived work order | Met | `service.py` calls `self.audit_service.log("work_order_archived", ...)` for each archived work order after the bulk archive flush. Test verifies this. |
| 6 | Limit batch size to 100 IDs per request | Met | Enforced in two places: Pydantic `max_length=100` on the list field (`schemas.py`) and explicit `len() > 100` check in `routes.py`. Both are present, though this creates a minor inconsistency (see findings). |

**Overall**: All six requirements are fully addressed by the implementation.

---

### Highlights

- **Tenant scoping baked into the query** -- `repository.py`'s `get_by_ids` filters by `tenant_id` and `deleted_at.is_(None)` directly in the SQL query rather than fetching all matching IDs and filtering in Python. This prevents a class of data-leak bugs where a tenant could reference another tenant's work orders, and it correctly respects soft-delete at the data layer.

- **Clean layering and flush-not-commit** -- The service, repository, and route layers each stay at one level of abstraction. The route is thin (validate batch size, delegate). The service orchestrates find/validate/archive/audit. The repository does data access and uses `session.flush()` instead of `session.commit()`, leaving transaction control to the caller -- the right pattern for composable operations.

- **Schema-level batch validation** -- `BulkArchiveRequest` in `schemas.py` uses `Field(..., max_length=100)` to enforce the batch size limit at the Pydantic layer, giving automatic 422 responses with clear error messages and documenting the constraint in the OpenAPI spec.

- **Thorough test coverage of failure paths** -- `test_bulk_archive.py` exercises rejection of in-progress work orders, missing IDs, mixed valid/invalid batches, and audit log creation. The mixed-scenario test is particularly valuable since it validates the partial-success behavior that is the trickiest part of a bulk operation.

---

### Findings

- **Critical**: **Type mismatch between service and repository** -- `src/work_orders/repository.py` declares `get_by_ids(self, work_order_ids: list[str], tenant_id: str)`, but the service passes `List[UUID]` from the Pydantic-validated request. SQLAlchemy's `in_()` may silently produce zero matches if the DB column is string-typed and receives UUID objects (or vice versa), causing every work order to be reported as "not found" even when they exist. The parameter type annotation should be `list[UUID]` to match the caller and the schema.

- **Critical**: **Atomicity gap between archive and audit logging** -- `src/work_orders/service.py` calls `repository.bulk_archive()` which flushes status changes to the DB within the current transaction, then calls `audit_service.log()` in a loop *after* the flush. If `audit_service.log()` raises an exception partway through (e.g., on the second of five work orders), the outcome depends on whether the audit service shares the same DB session/transaction. If it does, the entire transaction rolls back and successfully processed items are lost. If it doesn't, you get archived work orders with no audit trail. There is no error handling around the audit loop. Consider wrapping the audit calls in a try/except or ensuring both operations participate in the same transaction boundary.

- **Important**: **Duplicate and divergable batch-size validation** -- `src/work_orders/schemas.py` enforces `max_length=100` on the Pydantic field, and `src/work_orders/routes.py` also checks `len(request.work_order_ids) > 100`. The route check is effectively dead code since Pydantic rejects the request first with a 422. If someone later changes the limit in one place but not the other, they silently diverge. Pick one enforcement point (the schema is preferred since it also documents the constraint in OpenAPI) and remove the manual check in the route.

- **Important**: **No handling of empty input list** -- `src/work_orders/routes.py` / `src/work_orders/service.py`. Submitting an empty `work_order_ids` list would cause `WHERE id IN ()` in the repository query -- a SQL syntax error on some databases (e.g., older MySQL versions), and a wasted round-trip on those where it is valid. Add `min_length=1` on the Pydantic field or short-circuit in the service when the list is empty.

- **Important**: **Duplicate IDs not deduplicated** -- `src/work_orders/service.py`. If the caller sends the same UUID twice, set arithmetic (`found_ids = {wo.id for wo in work_orders}`) silently collapses the duplicates -- no error and no indication to the caller. However, this could also result in duplicate audit log entries if the same ID appears multiple times in the input and passes validation. Deduplicate `work_order_ids` at the top of the service method.

- **Important**: **Race condition on concurrent archive requests** -- `src/work_orders/service.py`. Two simultaneous requests for the same work order ID could both read `status = "completed"`, both flush `status = "archived"`, and both write audit log entries. This results in duplicate audit entries at minimum. Consider using `SELECT ... FOR UPDATE` in the repository query to lock rows, or checking `wo.status != "archived"` before proceeding.

- **Minor**: **`datetime.utcnow()` is deprecated** -- `src/work_orders/repository.py`. `datetime.utcnow()` has been deprecated since Python 3.12. Use `datetime.now(datetime.timezone.utc)` instead. Additionally, calling it inside the `for` loop means each work order in a batch gets a slightly different `archived_at` timestamp. Consider computing the timestamp once before the loop.

---

### What I Verified

- Traced the full request path from route through service to repository for both success and failure cases -- the happy path, missing IDs, and non-archivable statuses all produce correct response shapes.
- Confirmed tenant isolation: `get_by_ids` filters by `tenant_id` at the query level, so cross-tenant access returns "not found" rather than leaking data.
- Verified soft-delete handling: the repository query includes `deleted_at.is_(None)`, preventing archived or deleted records from being returned.
- Checked that `session.flush()` is used instead of `session.commit()` in the repository, correctly deferring transaction control.
- Confirmed `ARCHIVABLE_STATUSES` matches the ticket requirement (completed and cancelled).
- Verified the response schema (`BulkArchiveResponse`) matches the ticket's required shape with `archived` and `failed` fields.
- Checked for stale ticket references in code comments or docstrings in the diff additions -- none found.
- Reviewed test coverage: 5 test cases covering happy path (completed), rejection (in_progress), missing IDs, mixed scenarios, and audit logging. Noted gaps in coverage for empty lists, duplicate IDs, already-archived work orders, audit failure handling, the cancelled status path, and the HTTP 422 response for exceeding the batch limit.

---

### Summary

The PR cleanly satisfies all six ticket requirements with well-structured code and good test coverage of failure paths. However, there are two critical issues to address before merging: the type mismatch in the repository method signature (`list[str]` vs `List[UUID]`) could silently cause all lookups to return empty, and the atomicity gap between the archive flush and audit logging could leave the system in an inconsistent state. I would request changes to fix these two critical items and address the empty-list and duplicate-ID edge cases, then approve.
