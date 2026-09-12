---
name: commit-message
description: Draft a structured commit message from uncommitted changes (staged, unstaged, and untracked). Use when the user asks to write, draft, generate, or create a commit message, or says "what should my commit message be", "summarize my changes for a commit", etc. Do NOT use if the user asks to actually commit — this only drafts the message.
---

# Commit Message Drafter

Generate a commit message from the current working tree and print it to the terminal. The user will copy, adjust, and commit themselves — **never run `git commit`**.

## Gathering context

Run all of these in parallel:

1. `git branch --show-current` — the branch name often contains the ticket number
2. `git status` — staged, unstaged, and untracked files
3. `git diff --staged` — staged changes in detail
4. `git diff` — unstaged tracked-file changes
5. `git diff --stat` — summary of files changed and magnitude (useful for large diffs)

Then for any **untracked** files shown in `git status`:
- Skip binary files and generated artifacts (lock files, build output, `.min.js`, etc.)
- Read the first ~50 lines of each — enough to understand purpose, not the full contents
- If there are more than 10 untracked files, read the most important-looking ones and summarize the rest by filename

If there are no uncommitted changes at all, say so and stop.

## Inferring the ticket number

Check the branch name first. If it starts with a pattern like `VS-1234`, `PROJ-567`, `ABC-89` (letters, hyphen, digits), that's the ticket number. If the branch doesn't contain one (e.g. `main`, `feature/refactor-auth`), ask the user — or if they don't use tickets, leave the ticket prefix out entirely.

## Composing the message

Format:

```
<ticket> - <short title>

WHAT:
- <change 1>
- <change 2>
- ...

WHY:
<one or two sentences>

<attribution>
```

### First line

`<ticket> - <short title>` — a brief imperative-mood summary of the change (e.g. "Disallow createJob from guest org"). Keep it under ~70 characters total. If the branch name reads like a good title after stripping the ticket prefix, use it. Otherwise write one from the diff.

If the conversation makes the context behind this round of changes clear (addressing review comments, fixing CI, etc.), append it: `<ticket> - <short title> - <context>`. Only include this if the reason is obvious from conversation; don't invent one.

### WHAT section

A bulleted list of what changed. Each bullet must be **12 words or fewer** — terse, scannable, no filler.

- Group related changes into single bullets ("Add and update tests" not one per file)
- Use plain language, not file paths
- 3–6 bullets for a typical change; fewer is fine
- For very large diffs (20+ files), organize by area of change

### WHY section

One or two sentences explaining why this change is valuable or necessary — what a reviewer needs to know that isn't obvious from the diff. If the motivation is unclear, write your best guess and note the uncertainty so the user can adjust.

### Attribution

If the session has attribution guidance configured (e.g. a `Co-Authored-By` line in system instructions), use that. Otherwise, use:

```
Co-Authored-By: Claude <model name> <noreply@anthropic.com>
```

where `<model name>` is the model powering this conversation (e.g. `Opus 4.6`).

## Output

Print the complete commit message inside a fenced code block so the user can copy it. After the block, one sentence like "Adjust as needed and commit when ready." is fine.

If anything is ambiguous (motivation, ticket number, whether certain untracked files should be included), note it briefly after the message.
