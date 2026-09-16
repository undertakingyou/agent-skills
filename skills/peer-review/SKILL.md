---
name: peer-review
description: Peer-review a GitHub PR — optionally against a ticket from Jira, GitHub Issues, or a Coda document. Takes a PR number and an optional ticket reference, fetches both, then evaluates ticket fulfillment (when a ticket is provided), investigates logic bugs and edge cases, and checks for architectural concerns like cross-subproject coupling. Use when the user says "peer review", "review this PR", "review PR against ticket", "does this PR satisfy the ticket", or provides a PR number (with or without a ticket reference) and asks for a review. Works with Jira keys (WKD-123), GitHub issue numbers (#42), Coda doc URLs, or no ticket at all. Only triggers on explicit invocation.
---
# Peer Review

Review a GitHub PR — checking logic correctness, edge cases, and architectural health. When a ticket is provided (Jira, GitHub Issue, or Coda doc), also evaluate whether the PR fulfills the ticket's requirements.

**Arguments:** $ARGUMENTS

## Step 1: Parse Inputs

Extract from `$ARGUMENTS` or the conversation:
- **PR number** (required — e.g., `1282`, `#1282`)
- **Ticket reference** (optional — one of the following):
  - **Jira key**: `WKD-123`, `EQD-456` (uppercase project prefix + hyphen + number)
  - **GitHub Issue**: `#42`, `org/repo#42`, or a GitHub issues URL
  - **Coda doc**: a Coda URL (e.g., `coda.io/d/...`), or the user may paste document content directly
  - **None**: the user just gives a PR number, or says there's no ticket

If the PR number is missing, ask for it. If no ticket is mentioned, proceed without one — don't ask. The user can always volunteer a ticket reference if they have one.

## Step 2: Gather Context (in parallel)

Fetch the ticket (if provided) and PR diff at the same time.

### Ticket (if provided)

The goal is the same regardless of source: extract a **title**, **description/body**, and a concrete list of **requirements** (acceptance criteria, task bullet points, or described behaviors the PR should satisfy). If the ticket is vague (just a title, no description), note that and work with what's available.

#### Jira

Use the `jira` skill (invoke via the Skill tool with `skill: "jira"` and the ticket key as args) to fetch the ticket. You need:
- Summary / title
- Description (the full body — acceptance criteria, task list, or requirements live here)
- Status and type
- Any subtasks or linked issues that define additional scope

If the jira skill fails, fall back to `acli` directly:
```bash
acli jira issue view <TICKET-KEY> --output-format json
```

If that also fails, try the Atlassian MCP tools (`mcp__claude_ai_Atlassian_Rovo_2__getJiraIssue`).

#### GitHub Issue

```bash
gh issue view <ISSUE-NUMBER> --json title,body,labels,state
```

Extract requirements from the issue body the same way you would from a Jira description.

#### Coda

If the user pasted document content directly in the conversation, use that — no fetch needed.

Otherwise, if Coda MCP tools are available (look for tools matching `mcp__*coda*` or `mcp__*Coda*`), use them to fetch the document. If no Coda MCP is configured and you have a URL, try fetching it with WebFetch as a last resort.

Extract requirements from whatever structure the Coda doc uses — tables, checklists, or prose.

### PR diff and metadata

Run these in parallel:
```bash
gh pr view <PR-NUMBER> --json title,body,baseRefName,headRefName,files,additions,deletions,commits
```
```bash
gh pr diff <PR-NUMBER>
```

From the PR metadata, note the title, description, base branch, and scope (files changed, lines added/removed).

### Check out the PR branch

After fetching metadata and the diff, check out the PR branch so that source file reads reflect the PR's changes:

```bash
gh pr checkout <PR-NUMBER>
```

If the checkout fails (typically due to uncommitted changes), **stop and tell the user**. Do not stash, reset, or otherwise modify the user's working tree — they may have in-progress work that shouldn't be disturbed. Let them decide how to handle it.

### Sanity check: do the ticket and PR match? (ticket reviews only)

When a ticket was provided, verify that the ticket and PR are actually about the same piece of work before moving to analysis. Compare the ticket summary/description against the PR title/description and the files changed. If they don't appear related — for example, the ticket describes a search feature but the PR is a logging refactor — **stop and tell the user** what you found. Include the ticket summary, the PR title, and why they seem mismatched. Let the user confirm or correct the inputs before proceeding.

## Step 3: Analyze

Run the analyses in parallel as subagents (via the Agent tool). Pass each the PR diff, PR metadata, and the list of changed files. This parallelism matters — the code quality dive reads source files and takes real time, so running it alongside the other analyses saves wall-clock.

- **With a ticket**: run three subagents — ticket fulfillment, code quality, and highlights
- **Without a ticket**: run two subagents — code quality and highlights (skip fulfillment)

If subagents are unavailable, run all analyses sequentially in the main context.

### Subagent 1: Ticket Fulfillment (skip when no ticket)

Map each requirement from the ticket against the PR diff:

For each requirement:
1. **Identify** which files/changes address it (or note if nothing does)
2. **Assess** whether the implementation satisfies the requirement — fully, partially, or not at all
3. **Flag** requirements that appear unaddressed

Be precise — quote specific file paths and diff hunks when claiming a requirement is met. If the ticket is vague, assess against the PR's own stated intent (from its description) and note the ambiguity.

### Subagent 2: Code Quality Deep Dive

This is the core of the review. The goal is to catch things the author may have missed — logic bugs, unhandled edge cases, and architectural concerns that could cause problems down the line.

#### Read Beyond the Diff

The diff alone is insufficient for a real review. For each changed file:
- Read the **full function or class** surrounding each change to understand what the code is actually doing in context
- Check **callers** of modified functions — could existing callers break or behave differently with the new behavior?
- For new functions or methods, check whether the **interface** (parameters, return type, error behavior) is consistent with similar patterns in the codebase

This step is not optional. Reading surrounding code is how you find real bugs — a diff-only review catches surface issues at best.

#### Logic & Edge Cases

Work through these for each substantive change:

- **Trace each code path end-to-end.** What are the inputs? What are all possible outputs, including error cases? Where can it fail, and what happens when it does?
- **Probe boundary conditions.** What happens with None, empty strings, empty collections, zero, negative numbers, or extremely large inputs? Are these handled explicitly, or do they fall through to an implicit (and possibly wrong) default?
- **Check error handling.** Do exception handlers actually handle the failure modes they claim to? Are errors swallowed silently? Is there a bare `except` that masks real problems?
- **Look for race conditions.** Are there ordering dependencies, shared mutable state, or assumptions about sequence that could break under concurrency?
- **Check data access patterns.** If a new query was added, what happens with large result sets? Is there pagination or a limit? Could it N+1?

#### Architectural & Design Concerns

The guiding principle is **low coupling, high cohesion** — each module and subproject should own its data and responsibilities.

- **Cross-boundary coupling.** In a monorepo, subprojects should communicate through defined interfaces, not by reaching into each other's internals. Flag:
  - Querying another subproject's database tables directly instead of going through that subproject's service/repository layer
  - Importing modules from a subproject that isn't a shared library
  - Instantiating another subproject's internal classes directly
- **Abstraction consistency.** Is business logic mixed with infrastructure concerns (HTTP handling, raw SQL, serialization) in the same function? Each function should operate at one level of abstraction.
- **Pattern deviation.** Does this change follow the established patterns in the codebase, or does it introduce a novel approach to something that already has a convention? A deviation is fine if intentional, but accidental inconsistency is a maintenance burden.

#### Project Conventions

Load and reference these project skills as relevant to the files changed:

- **Service layer** (`service-layer-practices`): FCIS shape, constructor DI, transaction boundaries (never commit), authorization guards, pydantic Output models, no SQL in services
- **Repository layer** (`repository-layer-practices`): N+1 avoidance, tenant scoping, LIKE escaping, soft-delete filters, flush-not-commit
- **FCIS layout** (`fcis-layout`): pure core / impure shell separation
- **Logging** (`logging-mechanics`, `xoi-logging-and-errors`): structured logging, `get_logger(__name__)`, log-or-re-raise, level discipline

Only load skills relevant to the files actually changed.

#### Stale References

Check for **ticket numbers in code comments or docstrings** (e.g., `# WKD-123`, `TODO(EQD-456)`, `"""See INTAPI-99"""`). Ticket numbers belong in commit messages and branch names where they are searchable and linked to the ticket tracker — in code comments they become meaningless noise as soon as the ticket is closed or renumbered. Flag any that appear in the diff's additions.

#### What to Skip

Don't spend review budget on pure style or formatting issues (line length, quote style, import ordering) unless they cause genuine confusion. The value of this review is in finding things the author couldn't easily catch themselves.

### Subagent 3: Highlights

Identify 2-4 things the PR does well. Good reviews acknowledge strengths — it reinforces good habits and gives the author signal about what to keep doing. Look for things like:

- **Smart design choices** — a well-chosen abstraction, a clean separation of concerns, or a pattern that will make future work easier
- **Defensive coding** — thoughtful error handling, good edge-case coverage, or input validation that prevents a class of bugs
- **Readability wins** — clear naming, well-structured functions, or changes that leave the code more understandable than before
- **Testing quality** — thorough test cases, good use of fixtures, or tests that actually exercise meaningful behavior rather than just covering lines

Keep it genuine. The goal is to call out specific things worth recognizing, not to pad the review with generic praise. Each highlight should reference a concrete file or change.

## Step 4: Present the Review

Synthesize the results from all analyses into a single review. Output as terminal markdown. Use the appropriate template based on whether a ticket was provided.

### With ticket

```
## Peer Review: <TICKET-KEY> / PR #<NUMBER>

**Ticket**: <ticket summary>
**PR**: <PR title>
**Scope**: <N files changed, +X/-Y lines>

---

### Ticket Fulfillment

| # | Requirement | Status | Notes |
|---|-------------|--------|-------|
| 1 | <requirement> | Met / Partial / Unmet | <brief explanation with file refs> |
| 2 | ... | ... | ... |

**Overall**: <one-line verdict>

---

### Highlights

<2-4 specific things the PR does well, each referencing a concrete file or change.>

- <highlight>
- ...

---

### Findings

<List findings in severity order — most impactful first. Each finding should name the file:line, state what's wrong, and explain what could go wrong as a result.>

- **<severity>**: <finding>
- ...

<If the investigation turned up nothing substantive, say so — but only after genuinely investigating.>

---

### What I Verified

<List the specific things that were investigated and came back clean. This gives the reader confidence in what was covered, even when no issues were found.>

- <e.g., "Traced the `register_field` path for None/empty inputs — validated at the route layer before reaching the service">
- <e.g., "Checked all callers of `FieldCatalogRepository.get_by_id` — no behavioral change for existing callers">
- <e.g., "No cross-subproject imports or direct DB access across boundaries">
- ...

---

### Summary

<2-3 sentence overall assessment — would you approve, request changes, or want discussion?>
```

### Without ticket

When no ticket was provided, drop the Ticket Fulfillment section and the ticket line from the header:

```
## Peer Review: PR #<NUMBER>

**PR**: <PR title>
**Scope**: <N files changed, +X/-Y lines>

---

### Highlights

- <highlight>
- ...

---

### Findings

- **<severity>**: <finding>
- ...

---

### What I Verified

- ...

---

### Summary

<2-3 sentence overall assessment — would you approve, request changes, or want discussion?>
```

### Severity levels

- **Critical** — likely bug, security issue, or data loss risk. Something that could break in production.
- **Important** — architectural concern, missing test coverage, or design issue that will cause real pain later. Not an immediate bug, but a real problem.
- **Minor** — small improvements, stale ticket references in code, naming that could be clearer. Worth noting but not blocking.

### Tone

Be direct, thorough, and constructive. Your job is to be the skeptical second pair of eyes that catches what the author missed — not to find fault for its own sake, but to genuinely investigate whether the code is correct, well-structured, and safe to ship. Don't soften real concerns; explain *why* something is a problem and what could go wrong. If thorough investigation turns up nothing, say so and show your work in "What I Verified."
