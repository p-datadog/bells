# Log Viewer: Auto-Scroll to First Error

When viewing a CI job log, the page should automatically scroll to the first error so the user doesn't have to read through hundreds of lines of setup output to find what went wrong.

## Mechanism

The approach uses plain HTML fragment anchors — no JavaScript.

1. **Detection**: During log conversion, the cleaned plain text (ANSI codes stripped) is scanned line by line for known error patterns. The index of the first matching line is recorded.

2. **Anchor insertion**: An `<a id="first-error"></a>` element is inserted into the HTML output at the start of that line.

3. **Navigation**: Links to the log page append `#first-error` to the URL. The browser natively scrolls to the anchor. The log page itself shows a "Jump to error" link when an error was detected.

No JavaScript is involved. The browser handles the scroll via standard fragment navigation.

## Reference: How tenex Does It

[tenex](https://github.com/p-mongodb/tenex) implements the same pattern for Evergreen CI logs:

- **Detection** (`lib/fe/evergreen_cache.rb`): Scans each log line for `Failure/Error:` (RSpec marker). Stores the line index as `first_failure_index` in the cached build/task model.

- **Anchor** (`views/eg_log.slim`): While rendering log lines, inserts `<a name='first-failure'>` when the current line index matches `first_failure_index`.

- **Links** (`views/pull.slim`): Links to log pages use `#first-failure` as the URL fragment, e.g. `#{status.log_url}#first-failure`.

## Error Patterns

Patterns are defined in `Bells::AnsiToHtml::ERROR_PATTERNS`. Each is a regex matched against individual lines of cleaned plain text (ANSI codes stripped). The first match across all lines wins.

Current patterns:

| Pattern | Matches | Example |
|---------|---------|---------|
| `/\AError: /` | Line starts with "Error: " | `Error: There are validation errors:` (config validation) |
| `/Failure\/Error:/` | RSpec failure marker (anywhere in line) | `  Failure/Error: subject.call` |

### Adding New Patterns

Add a new regex to `ERROR_PATTERNS` in `lib/bells/ansi_to_html.rb`. Guidelines:

- Match against cleaned plain text (no ANSI codes, no GitLab prefixes).
- Use `\A` for start-of-line anchoring (each line is matched as a separate string).
- Be specific enough to avoid false positives on JSON keys, log metadata, etc.
- Do NOT match `ERROR: Job failed:` — that's the GitLab runner exit message on the last line, not the actual error.

### Future: RSpec Output

RSpec failures appear as:
```
  Failure/Error: expect(result).to eq(expected)

    expected: "foo"
         got: "bar"
```

The `Failure/Error:` pattern is already included. When we start viewing RSpec logs, this will automatically anchor to the first spec failure. If RSpec output needs additional patterns (e.g. `Errno::ECONNREFUSED`, `LoadError`), add them to `ERROR_PATTERNS`.

## Implementation Notes

- Error detection happens on the cleaned text (after CR simulation, prefix stripping, section marker removal, and clear sequence removal) but before ANSI-to-HTML conversion. ANSI codes are also stripped for pattern matching.
- Line numbers in the plain text correspond 1:1 with line numbers in the HTML output (the ANSI scanner doesn't add or remove newlines).
- The anchor is always inserted when a match is found. Callers check for its presence with `html.include?('id="first-error"')`.
