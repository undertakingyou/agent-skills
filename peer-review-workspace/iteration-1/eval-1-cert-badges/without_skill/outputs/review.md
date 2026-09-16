# Peer Review: PR #891 — feat: show cert status badges on dispatch board

**Ticket:** DEMO-202 — Show technician certification status on dispatch board

---

## Requirement Coverage

| Requirement | Status | Notes |
|---|---|---|
| Badge on each technician card (valid / expiring / expired) | Met | Badge renders with three states |
| Color-coded: green, yellow, red | Met | Colors mapped correctly in `CertBadge` |
| "Expiring soon" = within 30 days | Met | `computeStatus` checks `daysLeft <= 30` |
| Show worst status across multiple certs | Met | Priority map iterates all certs and keeps worst |
| Cert data from `certifications` subproject | Partially met | Data is retrieved, but via a direct internal import (see below) |

---

## Bugs and Issues

### 1. Server-side DB query called from a client-side React hook (Critical)

`useCertStatus.ts` is a React hook that uses `@tanstack/react-query`, which runs in the browser. Its `queryFn` calls `getTechCertifications()`, which executes `pool.query()` directly against the database. You cannot call a database connection pool from a browser-side React component. This code will not work at runtime — there needs to be an API endpoint (e.g., a REST route or tRPC procedure) between the React hook and the database query.

**Files:** `scheduling/src/dispatch/hooks/useCertStatus.ts`, `scheduling/src/dispatch/queries/certifications.ts`

### 2. Cross-subproject boundary violation (Major)

The ticket explicitly notes that cert data lives in the `certifications` subproject and the dispatch board is in `scheduling`. The PR reaches directly into the certifications subproject's internals:

```ts
import { pool } from "../../../certifications/src/db/connection";
```

This creates tight coupling between subprojects. The `scheduling` subproject should consume an API or shared service exposed by `certifications`, not import its DB connection directly. If the certifications subproject changes its database schema or connection setup, the scheduling code breaks silently.

**File:** `scheduling/src/dispatch/queries/certifications.ts`, line 1

### 3. N+1 query problem (Major)

`useCertStatus` is called once per `TechnicianCard`, and each call queries for a single technician. If the dispatch board shows 50 technicians, this fires 50 separate database queries. The `getTechCertifications` function already accepts an array of IDs, but it is always invoked with `[technicianId]` — a single-element array. The batching should be lifted to a higher level (e.g., query all visible technicians at once and distribute the results).

**File:** `scheduling/src/dispatch/hooks/useCertStatus.ts`, line 36

### 4. No loading or error handling (Moderate)

The hook destructures only `{ data: certs }` from `useQuery`, discarding `isLoading`, `isError`, and `error`. When the query is still loading or has failed, the hook returns `{ status: "valid" }`, making it appear the technician is fully certified. This is misleading — a failed fetch should not default to the most optimistic status. At minimum, add a "loading" or "unknown" state.

**File:** `scheduling/src/dispatch/hooks/useCertStatus.ts`, lines 33-34

### 5. No certifications treated as "valid" (Moderate)

When a technician has zero certification rows, the hook returns `{ status: "valid" }` and the badge reads "Certified." This is ambiguous: does it mean the technician needs no certifications, or that their data is missing? The product requirement should clarify the expected behavior, and the code should handle it explicitly (e.g., hide the badge, or show a distinct "No certs on file" state).

**File:** `scheduling/src/dispatch/hooks/useCertStatus.ts`, lines 38-40

---

## Minor Issues

### 6. Duplicated `CertStatus` type

The `CertStatus` type is defined independently in both `useCertStatus.ts` (line 5) and `CertBadge.tsx` (line 3). This should be defined once in a shared types file and imported by both.

### 7. `daysUntilExpiry` never populated

The `CertStatusResult` interface includes `daysUntilExpiry?: number`, but the worst-status loop never sets it. Either populate it or remove it from the interface to avoid confusion.

**File:** `scheduling/src/dispatch/hooks/useCertStatus.ts`, line 10

### 8. Inline styles vs. CSS classes

`CertBadge` uses inline `style` objects, while the existing `TechnicianCard` uses CSS class names (`technician-card`, `tech-name`, `tech-skills`). The badge should follow the same pattern for consistency and maintainability.

### 9. Color accessibility concern

The "expiring" badge uses yellow (`#eab308`) with white text. This combination is likely below WCAG AA contrast requirements (~2.8:1 ratio vs. the 4.5:1 minimum for small text). Consider using dark text on the yellow badge, or a darker amber.

### 10. No tests

The PR description mentions only manual testing. The `computeStatus` function is pure and straightforward to unit test. The `CertBadge` component is simple enough for a snapshot or render test. The worst-status logic deserves test coverage for edge cases (all valid, mixed, all expired, empty array).

---

## What's Good

- **Clean status priority design.** The `STATUS_PRIORITY` map with numeric ordering is a clear and extensible way to compute worst status.
- **SQL injection prevention.** The query uses parameterized placeholders (`$1`, `$2`, ...) rather than string interpolation.
- **Soft-delete awareness.** The query filters `deleted_at IS NULL`, correctly respecting soft-deleted records.
- **Small, focused components.** `CertBadge` is a simple presentational component with clear props — easy to reuse elsewhere.
- **Commit structure.** Two logical commits that separate the component from the wiring.

---

## Summary

The PR fulfills the visible UI requirements from DEMO-202 (badge, colors, worst-status logic), but has a critical runtime issue: a direct database call from a React hook will not execute in the browser. The cross-subproject import is an architectural concern that should be resolved before merge. Loading/error states and the N+1 query pattern also need attention. I would recommend addressing items 1-4 before merging.
