# PR #1340 Review: refactor: extract shared email template rendering

## Overview

This PR extracts duplicate Jinja2 template rendering logic from the notification service and the report-delivery service into a shared `TemplateRenderer` class under `src/shared/email/`. It also removes the old `EmailBuilder` class and its dead Mailgun code. The refactor is well-motivated and the resulting code is cleaner. However, there are several issues ranging from a likely runtime breakage to subtle behavioral changes that need to be addressed before merging.

---

## Critical

### 1. Template directory mismatch will cause runtime errors

The new `TemplateRenderer()` defaults to `src/shared/email/default_templates/` when no `template_dir` is passed. Both `NotificationService` and `ReportSender` instantiate `TemplateRenderer()` without arguments, meaning they will look for templates in that default directory.

Previously:
- `EmailBuilder` loaded templates from `src/notifications/templates/`
- `ReportSender` loaded templates from `src/report_delivery/templates/`

The diff does not show any template files being moved or copied to `src/shared/email/default_templates/`, nor do the callers pass their old template directories. This will result in `jinja2.TemplateNotFound` errors at runtime.

**Recommendation:** Either move the template files to the shared location (and include that in this PR), or have each service pass its own template directory to the constructor. If templates are genuinely shared, move them. If they differ per service, each caller should pass its path.

### 2. Enabling autoescape is a behavioral change

The old `EmailBuilder` and `ReportSender` did **not** enable Jinja2 autoescape. The new `TemplateRenderer` enables `select_autoescape(["html", "xml"])`.

This is a security improvement, but it's also a breaking change for any templates that intentionally pass raw HTML through context variables (e.g., rich-text content, pre-rendered HTML snippets). Those values will now be escaped, potentially rendering as visible `&lt;` / `&gt;` in emails.

**Recommendation:** Audit existing templates for any context variables that contain intentional HTML. If found, use Jinja2's `| safe` filter in those templates, or use `Markup()` when passing the values. Either way, call this out in the PR description as a deliberate change.

---

## High

### 3. `current_year` is hardcoded

In `src/shared/email/templates.py`:

```python
"current_year": "2026",
```

This will silently become wrong on January 1, 2027. Use `str(datetime.now().year)` or compute it at render time rather than module load time (to handle long-running processes spanning year boundaries).

### 4. `reply_to` support was dropped

The old `EmailBuilder.build()` accepted an optional `reply_to` parameter and conditionally included it in the returned dict. The new `TemplateRenderer.render()` has no such parameter. If any caller relied on `reply_to`, this is a silent regression. Even if no current caller uses it, the capability was intentionally built and removing it should be a conscious decision, not an accidental omission.

**Recommendation:** Confirm no callers pass `reply_to`. If it was truly unused, fine to drop it, but note the removal in the PR description.

---

## Medium

### 5. `TEMPLATE_REGISTRY` is defined but never used

`src/shared/email/templates.py` defines `TEMPLATE_REGISTRY` mapping logical names to filenames, but nothing in the PR references it. `TemplateRenderer.render()` takes raw filename strings directly. This is dead code on arrival.

**Recommendation:** Either wire it into the renderer (e.g., `render("welcome")` resolves via the registry) or remove it. Shipping unused code in a refactor whose goal is removing dead code sends mixed signals.

### 6. Missing `__init__.py` files

The diff introduces new packages at `src/shared/email/` and `tests/shared/email/` but does not show `__init__.py` files being created. If these directories are new and the project does not use implicit namespace packages, imports will fail.

### 7. `re` imported inside a method

In `renderer.py`, `_strip_html` imports `re` inside the function body. This was carried over from the old `ReportSender._strip` pattern. It works but is unconventional -- `re` should be a top-level import.

---

## Low / Nits

### 8. `unsubscribe_url` defaults to empty string

```python
"unsubscribe_url": "",
```

An empty string in an `href` attribute will create a link that navigates to the current page, which is confusing for recipients. Consider using `None` and handling the absence in templates with a conditional, or omitting the key entirely and letting templates check `{% if unsubscribe_url %}`.

### 9. Test coverage considerations

- `NotificationService` tests now use `MagicMock()` for the renderer, so actual rendering behavior is no longer exercised through the notification path. This is fine for unit isolation but means integration-level coverage decreased.
- No tests exist for `ReportSender` with the new renderer. The old `ReportSender._strip` had different behavior than `TemplateRenderer._strip_html` (no newline collapsing), so the text_body output for report emails will subtly change.
- No test covers `TemplateRenderer` instantiation with the default `template_dir` (i.e., without passing one). If the default directory doesn't exist, that path is untested.

### 10. Line length in `sender.py`

```python
rendered = self.renderer.render("report_ready.html", {"report": report}, subject=f"Report Ready: {report.title}")
```

This line is quite long. Consider breaking it across multiple lines for readability.

---

## What looks good

- The motivation is sound: deduplicating rendering logic across two services is the right call.
- Clean commit history with logical separation (extract, delete dead code, add tests).
- Tests cover the core rendering paths including XSS autoescape validation and default context override behavior.
- The API surface (`render` and `render_string`) is simple and sufficient.
- Removing the dead Mailgun code is welcome cleanup.

---

## Summary

The refactor direction is good, but the template directory mismatch (issue #1) is likely a runtime-breaking bug that needs to be resolved. The autoescape behavioral change (#2) and hardcoded year (#3) should also be addressed before merge. The remaining items are lower priority but worth fixing while the code is being touched.
