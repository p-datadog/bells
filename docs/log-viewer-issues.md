# Log Viewer: Known Transformation Issues and Fixes

Documents the quirks of GitLab CI log format and how `AnsiToHtml` handles them.

## GitLab Log Format

Each raw log line has the form:

```
TIMESTAMP STREAM_ID[+] CONTENT\n
```

- `TIMESTAMP`: ISO 8601 with nanoseconds, e.g. `2026-03-18T21:10:26.489682Z`
- `STREAM_ID`: two-digit stream number + `O` (stdout) or `E` (stderr), e.g. `00O`, `01E`
- `+` suffix on stream ID: continuation marker (no semantic meaning for display)
- Occasional trailing `\r` before `\n` on lines containing section markers

## Issue 1: `\A` Anchor — Prefix Only Stripped from First Line (Fixed)

**Root cause**: `GITLAB_PREFIX` used `\A` which anchors to the start of the entire string, not each line. `gsub` only matched once.

**Symptom**: All lines except the very first displayed raw timestamps.

**Fix**: Removed `\A`; the pattern now matches all occurrences anywhere in the string.

## Issue 2: Multi-Prefix Lines (Fixed as a consequence of Issue 1)

**Root cause**: Section markers end with `\r\n`; `SECTION_MARKER` consumes that `\n`. So the line following a section marker has no `\n` separating it from the previous line's (unstripped) timestamp — the two prefixes appear concatenated on one display line.

Example rendered output before fix:
```
2026-03-18T21:10:26.489709Z 00O 2026-03-18T21:10:26.489711Z 00O+Preparing the "kubernetes" executor
```

**Fix**: Removing `\A` makes both prefixes get stripped, regardless of position in the string.

## Issue 3: Carriage Return / Progress Bar Lines (Fixed)

**Root cause**: Tools like curl use `\r` to overwrite progress output on the same terminal line. The old code did `gsub("\r", "")` which concatenated all intermediate states into one long string.

Example raw log fragment:
```
  0     0    0     0\r100  1368  100  1368\r
```
Old rendering: `  0     0    0     0100  1368  100  1368`

**Fix**: Before any other processing, split each newline-separated line on `\r` and keep only the last non-empty segment, simulating terminal overwrite. This shows the final visible state of each progress line.

## Issue 4: Section Marker with `[0K` Prefix

Section marker lines often have `[0K` (clear-to-end-of-line) before the `section_start`/`section_end` token, e.g.:

```
2026-03-18T21:10:26.490291Z 00O+[0Ksection_start:1773868226:prepare_script[collapsed=true]\r\n
```

Processing order matters: `SECTION_MARKER` is stripped before `CLEAR_SEQUENCE`, which works because `SECTION_MARKER` matches starting at `section_start`, leaving `[0K` to be stripped in the next pass. Do not reorder these steps.

## Issue 5: Scroll Position Not Restored on Reload (Open)

**Symptom**: Reloading the page in Chrome moves the scroll position instead of staying where it was.

**Root causes**:

1. **`<style>` tags in `<body>` cause layout reflow during progressive rendering.** Chrome saves the scroll position before the reflow completes, then restores to that pixel offset after — but the content height has shifted so it lands in the wrong place. Fixed by moving all styles to `<head>` (done), but this alone did not fully resolve the issue.

2. **Chrome scroll restoration is unreliable for large pages and aggressively cached pages.** The page is served with `Cache-Control: public, max-age=604800`. Chrome may treat a reload as a fresh navigation rather than a history restore, losing the saved scroll position. This is a known Chrome issue — see [whatwg/html #10597](https://github.com/whatwg/html/issues/10597) and [Next.js #37893](https://github.com/vercel/next.js/issues/37893).

**What does NOT work**:
- JavaScript sessionStorage save/restore added at the bottom of `<body>`: Chrome applies its own scroll restoration *after* `load`, overriding the manual `scrollTo`. The JS fights Chrome's restoration and makes it worse.
- `history.scrollRestoration = 'manual'` set at the bottom of `<body>`: too late — Chrome has already queued its own restoration by then.

**Correct fix** (not yet implemented): Set `history.scrollRestoration = 'manual'` in an inline `<script>` in `<head>` (before any rendering), then use sessionStorage to save on scroll and restore at end of body. The `<head>` placement prevents Chrome from ever queueing its own restoration.

```html
<!-- in <head> -->
<script>history.scrollRestoration = 'manual';</script>

<!-- at end of <body> -->
<script>
  const k = 'scroll:' + location.pathname + location.search;
  const y = sessionStorage.getItem(k);
  if (y !== null) window.scrollTo(0, +y);
  window.addEventListener('scroll', () => sessionStorage.setItem(k, window.scrollY), { passive: true });
</script>
```

**References**:
- https://developer.chrome.com/blog/history-api-scroll-restoration
- https://github.com/whatwg/html/issues/10597
- https://www.aworkinprogress.dev/scroll-position-restoration--how-its-done--how-its-lost--and-how-its-fixed

## Non-Issue: `\r\n` Line Endings

Many lines end with `\r\n`. The `\r` simulation (Issue 3 fix) handles these correctly: splitting on `\r` turns `content\r` (before the `\n`) into `["content", ""]`; the last non-empty segment is `"content"`. No separate `\r` stripping needed.
