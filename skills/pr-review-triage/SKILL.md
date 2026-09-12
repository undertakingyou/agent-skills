---
name: pr-review-triage
description: Triages PR review comments — fetches all comments from a GitHub PR, ranks them by criticality, suggests resolutions, and presents a numbered table for the user to pick which items to address.
---

# PR Review Triage

Triage and prioritize review comments on a GitHub Pull Request. This skill is read-only — it does **not** make code changes.

## Input

The user may provide a PR number as an argument. If no PR number is provided, detect it from the current branch.

## Procedure

### Step 1 — Resolve the PR

If a PR number was provided as an argument, use it directly. Otherwise, detect the PR for the current branch:

```
gh pr view --json number,title,url,headRefName
```

If no PR is found for the current branch, tell the user and stop.

### Step 2 — Fetch all comments

Run these commands to collect every comment on the PR. Use the PR number from Step 1.

**General conversation comments:**
```
gh api repos/{owner}/{repo}/issues/{PR_NUMBER}/comments --paginate
```

**Review-level comments (approve / request-changes / comment bodies):**
```
gh api repos/{owner}/{repo}/pulls/{PR_NUMBER}/reviews --paginate
```

**Inline review thread comments (code-level feedback):**
```
gh api repos/{owner}/{repo}/pulls/{PR_NUMBER}/comments --paginate
```

To get `{owner}/{repo}`, run:
```
gh repo view --json nameWithOwner --jq .nameWithOwner
```

Collect every comment into a single list. For each comment, capture:
- **author** — the GitHub login of the commenter
- **body** — the comment text
- **source** — one of: `conversation`, `review`, `inline`
- **file / line** — for inline comments, the file path and line number
- **created_at** — timestamp
- **url** — link to the comment on GitHub
- **state** — for review comments, whether the thread is resolved

### Step 3 — Filter and deduplicate

- Exclude bot comments (author login ending in `[bot]` or known CI bots).
- Exclude resolved review threads — only surface unresolved feedback.
- Exclude empty review bodies (GitHub creates a review object with an empty body for plain approvals).
- Deduplicate: if the same author left the same text in both a review body and an inline comment, keep only the inline one.

### Step 4 — Analyze each comment

For every remaining comment, determine:

1. **Validity** — Is this actionable feedback, or is it a question, praise, acknowledgment, or conversational noise? Only keep actionable items (bugs, requested changes, suggestions, nits). If a comment is purely a question, note it as informational but still include it at the bottom.

2. **Criticality** — Assign one of:
   - **Critical** — Correctness bug, security issue, data loss risk, broken functionality. Must fix before merge.
   - **High** — Logic error, missing edge case, meaningful perf regression, API contract violation. Should fix.
   - **Medium** — Code quality, readability, naming, missing tests for non-trivial logic, non-idiomatic patterns.
   - **Low** — Style nits, typos, minor naming preferences, optional refactors, "consider doing X".
   - **Info** — Questions or observations that don't request a change.

3. **Resolution** — Write one sentence describing what the fix or response would be. For info-level items, suggest a reply instead of a code change.

### Step 5 — Display the triage table

Sort comments by criticality (Critical → High → Medium → Low → Info), then by file path for inline comments.

Print the PR title and URL first, then list each item in a compact card format — one item per block, no wide table:

```
● PR #123: "Add user authentication" — https://github.com/org/repo/pull/123

1. [Critical] src/auth.ts:42 — reviewer1
   Token is never validated before use
   ↳ Add JWT validation call before accessing claims

2. [High] src/db.ts:88 — reviewer2
   Missing null check on query result
   ↳ Guard with early return when result is undefined

3. [Medium] src/auth.ts:15 — reviewer1
   Consider extracting to a helper
   ↳ Extract repeated logic into validateSession()

4. [Low] reviewer2
   Typo in PR description
   ↳ Fix spelling of "authentication"

5. [Info] reviewer1
   "Should this also handle OAuth?"
   ↳ Reply clarifying scope of this PR
```

Formatting rules for each item:
- **Line 1**: Number, criticality tag in brackets, file:line (if inline) or omit (if conversation/review-level), then `—` and the author.
- **Line 2**: The description — what the reviewer said, condensed to one line.
- **Line 3**: `↳` followed by the suggested resolution.
- Separate items with a blank line.

After the table, print a summary line:
```
X comments triaged: N critical, N high, N medium, N low, N info
```

### Step 6 — Await user input

Ask the user:

> Which items would you like to work on? Enter numbers (e.g. `1,2,3`), `all`, or `none`.

Wait for the user's response. Do **not** proceed to make any code changes — this skill is for triage only. Once the user selects items, summarize the selected items as a checklist they can carry into their next task.

## Important

- Do NOT modify any files. This skill is read-only.
- Do NOT create branches or commits.
- If `gh` is not installed or not authenticated, tell the user and stop.
- Keep descriptions in the table concise — one line each, truncated if necessary.
