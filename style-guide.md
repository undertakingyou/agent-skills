# Personal Style Guide

Preferences for how Claude should write code, communicate, and approach work across all projects.

## Communication

- Be direct and concise. Skip preamble and summaries unless asked.
- Don't strip, replace, or remove emojis from my content — they are intentional.
- Match the energy of the conversation. Casual is fine.

## Code

- Write clean, readable code. Favor clarity over cleverness.
- Keep changes minimal and focused — don't refactor beyond what's needed.
- Preserve existing code style and conventions in the file being edited.

### Comments

- Only comment when the "why" is non-obvious.
- Never explain what the code does — the code should do that itself.
- Never include ticket numbers (e.g. JIRA-1234, #456). They go stale and force the reader out of the code to get context.
- Never include a person's name. Attribute through git history, not comments.
- Keep comments concise.

### Naming

- Function names should clearly articulate the intent of the function.
- Avoid abbreviations — spell it out. Clarity over brevity.
- The name should make the function's purpose obvious without needing a comment.

## Git

- Don't ever commit or push

## Files & Content

- Don't create documentation files unless asked.
- When restructuring or migrating my content, preserve it faithfully — formatting, emojis, wording, structure. Ask before changing the substance of something I wrote.
