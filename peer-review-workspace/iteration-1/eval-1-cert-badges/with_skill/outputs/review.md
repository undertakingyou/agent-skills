## Peer Review: DEMO-202 / PR #891

**Ticket**: Show technician certification status on dispatch board
**PR**: feat: show cert status badges on dispatch board
**Scope**: 4 files changed, +135/-4 lines

---

### Ticket Fulfillment

| # | Requirement | Status | Notes |
|---|-------------|--------|-------|
| 1 | Badge showing cert status (valid/expiring/expired) with 30-day threshold | Met | `computeStatus()` in `useCertStatus.ts` uses 30-day threshold; badge rendered via `CertBadge` in `TechnicianCard` |
| 2 | Certification data from `certifications` subproject | Met | Data is fetched from certifications subproject, though via direct cross-subproject DB import rather than a service boundary (architectural concern, not a fulfillment gap) |
| 3 | Color-coded: green for valid, yellow for expiring, red for expired | Met | `STATUS_COLORS` in `CertBadge.tsx` maps correctly: valid -> #22c55e (green), expiring -> #eab308 (yellow), expired -> #ef4444 (red) |
| 4 | Multiple certs -> show worst status | Met | `STATUS_PRIORITY` in `useCertStatus.ts` ranks expired(0) < expiring(1) < valid(2); iteration selects the worst across all certs |

**Overall**: All four ticket requirements are functionally satisfied. The implementation delivers the right behavior, but the how raises architectural concerns addressed below.

---

### Highlights

- **Clean data/presentation separation** -- The PR splits certification status into three well-scoped layers: a query function (`certifications.ts`), a logic hook (`useCertStatus.ts`), and a pure presentational component (`CertBadge.tsx`). `CertBadge` takes a single `status` prop and owns nothing about how that status was determined. This makes each piece independently testable and keeps the `TechnicianCard` integration to just two lines of new code.

- **Declarative worst-status aggregation** -- The `STATUS_PRIORITY` map in `useCertStatus.ts` is a clean alternative to nested conditionals or switch statements for finding the worst certification. It makes the priority ordering explicit and easily extensible -- adding a new status level is a one-line map entry, not a refactor of comparison logic.

- **Good use of react-query** -- Wrapping the cert lookup in `useQuery` with a `["certStatus", technicianId]` key gives automatic caching and deduplication. If the dispatch board re-renders or multiple components reference the same technician, the query won't fire redundantly.

- **Parameterized query construction** -- In `certifications.ts`, the query uses positional `$N` placeholders built from the array index rather than string interpolation, which prevents SQL injection. The `deleted_at IS NULL` filter also shows awareness of the soft-delete convention.

---

### Findings

- **Critical**: **Cross-subproject database coupling** -- `scheduling/src/dispatch/queries/certifications.ts:1` imports the DB connection pool directly from `../../../certifications/src/db/connection` and queries `certifications.technician_certs` with raw SQL. This reaches across the subproject boundary into certifications' internals. The certifications team cannot change their schema, table names, or connection pooling without breaking the scheduling subproject. The ticket itself acknowledges these are separate subprojects. The fix is to expose a service or API endpoint from the certifications subproject and have scheduling call that instead.

- **Critical**: **Empty array produces invalid SQL** -- `scheduling/src/dispatch/queries/certifications.ts:12-18`. If `technicianIds` is an empty array, `placeholders` becomes an empty string and the query becomes `WHERE technician_id IN ()`, which is a SQL syntax error that will crash at runtime. There is no guard against empty input.

- **Critical**: **N+1 query pattern** -- `scheduling/src/dispatch/hooks/useCertStatus.ts:33` combined with `TechnicianCard.tsx`. The `useCertStatus` hook is called once per technician card, each issuing a separate DB query. A dispatch board showing 50 technicians will fire 50 individual queries. The `getTechCertifications` function already accepts an array of IDs, but the hook only ever passes a single-element array. The fetching should be lifted to a parent component that batches all technician IDs into a single query, then distributes results down.

- **Critical**: **Missing API layer between server and client** -- `scheduling/src/dispatch/hooks/useCertStatus.ts:35`. The `getTechCertifications` function uses `pool.query` which is a server-side Node.js `pg` operation, but it's imported directly into a React Query hook running in a browser component. Unless there is a server-component or server-action framework bridging this (e.g., Next.js RSC or server actions), this function will fail at runtime in the browser because `pg` doesn't run in the browser.

- **Important**: **"No certs" defaults to "valid"** -- `useCertStatus.ts:38-40`. When a technician has zero certifications, or while the query is still loading, the hook returns `{ status: "valid" }`, rendering a green "Certified" badge. A technician with no certifications is not certified -- displaying them as "Certified" is actively misleading to dispatchers making assignment decisions. This should be a distinct state (e.g., "Unknown" or "No Certs") or at minimum not display a badge at all.

- **Important**: **Loading and error states not handled** -- `useCertStatus.ts:33-34`. Only `data` is destructured from `useQuery`; `isLoading`, `isError`, and `error` are ignored. While the query is in-flight, every technician shows a green "Certified" badge. If the certifications DB is down or the query fails, the badge stays permanently green with no error indication. At minimum, return a loading state so the UI can show a skeleton or placeholder, and handle errors so a failed fetch doesn't silently display incorrect status.

- **Important**: **`daysUntilExpiry` declared but never populated** -- `useCertStatus.ts:9`. The `CertStatusResult` interface declares `daysUntilExpiry?: number` but the value is never computed or set anywhere in the code. This is dead interface surface that will confuse consumers who expect it to be populated.

- **Minor**: **Ticket number in code comment** -- `TechnicianCard.tsx`: `{/* DEMO-202: show cert badge */}`. Ticket numbers belong in commit messages and branch names where they are searchable and linked to the ticket tracker. In code comments they become meaningless noise as soon as the ticket is closed or renumbered.

- **Minor**: **`CertStatus` type duplicated** -- The `CertStatus` type is defined independently in both `useCertStatus.ts:4` and `CertBadge.tsx:3`. If these diverge, the component will accept statuses the hook never produces (or vice versa). Extract it to a shared types file.

- **Minor**: **Client-side time dependency** -- `useCertStatus.ts:12-13`. `computeStatus` uses `new Date()` on the client side. If `expires_at` is stored as UTC in the database but the client is in a different timezone, the 30-day boundary could shift by up to a day. Consider using UTC consistently or computing status server-side.

---

### What I Verified

- Traced the `computeStatus` function for boundary values: daysLeft of -1 (expired), 0 (expiring), 30 (expiring), 31 (valid) -- threshold logic is correct at each boundary
- Verified the worst-status aggregation loop handles the case where all certs are valid, all are expired, and a mix -- the `STATUS_PRIORITY` comparison correctly selects the worst
- Confirmed the parameterized query uses positional placeholders (`$1, $2, ...`) with the array passed separately, preventing SQL injection
- Checked that the soft-delete filter (`deleted_at IS NULL`) is applied to the certification query
- Verified `CertBadge` color mapping matches the ticket requirements (green/yellow/red for valid/expiring/expired)
- Confirmed the badge renders inside `TechnicianCard` and receives the computed status

---

### Summary

The PR delivers all four ticket requirements and the internal code organization (query/hook/component separation, priority map pattern, react-query usage) is genuinely well done. However, there are several critical issues that need resolution before merging. The direct cross-subproject database import is an architectural violation that will create coupling pain as the codebase evolves. The N+1 query pattern will cause performance problems at scale. The missing API layer between the server-side query function and the client-side React hook may cause a runtime failure. And the "no certs = valid" default is misleading for dispatchers. I would request changes -- the architectural and correctness issues are significant enough to warrant a revision, even though the feature logic itself is sound.
