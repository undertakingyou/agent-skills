## Peer Review: PR #1340

**PR**: refactor: extract shared email template rendering
**Scope**: 7 files changed, +155/-170 lines

---

### Highlights

- **Security upgrade via autoescape** (`src/shared/email/renderer.py`): The new `TemplateRenderer` adds `select_autoescape(["html", "xml"])`, which neither the old `EmailBuilder` nor `ReportSender` had. This closes an XSS vector on every email template rendered through the shared class, and the test in `test_autoescape_html` explicitly verifies that script tags are escaped. Improving security posture as a side effect of a refactor is exactly the kind of thing worth calling out.

- **Clean constructor DI makes the shared class testable and flexible** (`src/shared/email/renderer.py`, `src/notifications/service.py`, `src/report_delivery/sender.py`): The `TemplateRenderer` accepts an optional `template_dir` parameter, and both consuming services accept an optional `renderer` parameter. This means each service can be tested with a mock or a custom template directory without touching the filesystem or relying on production templates. The tests demonstrate this immediately by using `tmp_path` to create isolated template fixtures.

- **Net code reduction while adding capability** (project-wide): The PR removes 170 lines and adds 155, a net reduction of 15 lines, while simultaneously adding a shared abstraction, new unit tests, and removing dead Mailgun code (`_format_mailgun_payload`, `_batch_mailgun_send`). Refactors that leave the codebase smaller and better-tested are the gold standard.

- **Thorough test coverage for the new shared class** (`tests/shared/email/test_renderer.py`): The tests cover basic rendering, default context injection, text body generation (HTML stripping), `render_string`, context override of defaults, and autoescape/XSS prevention. That is solid coverage for a 48-line class, and each test targets a distinct behavior rather than just chasing line coverage.

---

### Findings

- **Critical**: **Template directory default will break both consumers at runtime** (`src/shared/email/renderer.py`). When `template_dir` is `None` (the default), the renderer resolves to `src/shared/email/default_templates/`. Previously, `NotificationService` loaded templates from `src/notifications/templates/` and `ReportSender` from `src/report_delivery/templates/`. Both services now fall back to `TemplateRenderer()` with no args via the `or TemplateRenderer()` pattern in their constructors. This means every default-constructed renderer looks in a directory that almost certainly does not exist and does not contain the service-specific templates. Every `render()` call will raise `jinja2.TemplateNotFound`. This is masked in tests because `test_renderer.py` passes an explicit `template_dir` and `test_service.py` uses `MagicMock()`.

- **Critical**: **`reply_to` support silently dropped** (`src/shared/email/renderer.py`). The old `EmailBuilder.build()` accepted a `reply_to: str | None` parameter and conditionally included it in the returned dict. The new `TemplateRenderer.render()` has no `reply_to` parameter at all. Any caller that relied on reply-to headers will either get a `TypeError` (if passing it as a keyword argument) or silently lose the header on outgoing emails.

- **Important**: **Hardcoded `current_year` will go stale** (`src/shared/email/templates.py`). `"current_year": "2026"` is a hardcoded string newly introduced in `DEFAULT_CONTEXT`. When the calendar rolls to 2027, every email footer will still say 2026. This should be dynamic, e.g., `str(datetime.date.today().year)`.

- **Important**: **`TEMPLATE_REGISTRY` is defined but never used** (`src/shared/email/templates.py`). The registry maps logical template names to filenames, but nothing in the diff references it. This is dead code introduced in the same PR that removes dead code. Either wire it into `TemplateRenderer.render()` as a lookup layer or remove it until it is needed.

- **Important**: **Notification service tests lost integration coverage** (`tests/notifications/test_service.py`). The old fixture used a real `EmailBuilder`; the new fixture uses `MagicMock()`. Nothing now tests `NotificationService` + `TemplateRenderer` end-to-end, so a wiring mistake (like the template directory issue above) would not be caught.

- **Important**: **No tests for `ReportSender` with the new renderer** (absent from diff). The `ReportSender` constructor signature changed to accept an optional `renderer` parameter, but no test file updates appear in the diff. If tests exist for `ReportSender`, they may be broken by the constructor change.

- **Minor**: **Missing `__init__.py` for `src/shared/email/` package**. No `__init__.py` appears in the diff for the new `src/shared/email/` directory. If the project does not use implicit namespace packages (PEP 420), this will cause `ModuleNotFoundError` on import.

- **Minor**: **`_strip_html` does not decode HTML entities** (`src/shared/email/renderer.py`). The plaintext fallback body could contain raw `&amp;`, `&lt;`, etc. For a plaintext email fallback this is acceptable but not ideal -- consider running `html.unescape()` after stripping tags.

- **Minor**: **`render_string` inherits `FileSystemLoader` context** (`src/shared/email/renderer.py`). Because `render_string` calls `self.env.from_string()`, templates passed as raw strings could use `{% include %}` or `{% extends %}` to pull in filesystem templates. This is likely unintentional for an inline-string rendering method and could be a surprising vector if template strings ever come from user input.

---

### What I Verified

- No stale ticket references (e.g., `WKD-123`, `TODO(EQD-456)`) in any added code or comments.
- Autoescape is correctly enabled on the new `Environment` -- this is a security improvement over both old implementations which lacked it.
- Context merge order is correct: `{**DEFAULT_CONTEXT, **(context or {})}` means caller-supplied values override defaults, which is the intended behavior. The test `test_custom_context_overrides_defaults` validates this.
- No cross-subproject coupling introduced. Both `notifications` and `report_delivery` depend on `src/shared/`, which is the correct dependency direction for a shared library.
- The `render()` return dict keys (`subject`, `html_body`, `text_body`) match what both consumers expect. `ReportSender.send_report()` spreads the result with `{"to": to, **rendered}`, and `NotificationService.send_email()` assigns directly from the result.
- The behavioral change in newline collapsing for `ReportSender` plaintext (old `_strip()` did not collapse `\n{3,}`, new `_strip_html` does) aligns with what the notification path already did, so this is a convergence toward consistent behavior, not a regression.

---

### Summary

The refactoring direction is sound -- extracting shared rendering logic, adding autoescape, and cleaning up dead Mailgun code are all good moves. However, there are two critical issues that need to be resolved before merging. First, the default `template_dir` points to a `default_templates/` directory that likely does not exist, which means any default-constructed `TemplateRenderer` will fail at runtime; this is hidden by the current test strategy of mocking the renderer. Second, the `reply_to` parameter supported by the old `EmailBuilder` was dropped without a replacement, which could silently break email headers for any callers that relied on it. I would request changes on these two items and ask for clarification on the unused `TEMPLATE_REGISTRY` and the hardcoded year.
