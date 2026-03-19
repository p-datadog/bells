# GitLab CI Job Log Format

Reference for the raw log format returned by the GitLab Runner trace API (`GET /projects/:id/jobs/:job_id/trace`).

Enabled by the Runner's `FF_TIMESTAMPS` feature flag (Runner 17.0+). Each raw log line has the form:

```
TIMESTAMP STREAM_HEADER CONTENT\n
```

Example: `2026-03-18T21:10:26.489682Z 00O Running with gitlab-runner`

## Timestamp

RFC 3339 / ISO 8601 with microsecond precision in UTC: `2026-03-18T21:10:26.489682Z`. The first 32 characters of each line. Optional — absent when `FF_TIMESTAMPS` is disabled.

## Stream header

Format: `<stream_number><stream_type>[<line_type>]`

- **stream_number** (2 hex chars): identifies the output stream. `00` = runner control (executor setup, artifact downloads, section markers), `01` = job script stdout/stderr.
- **stream_type** (1 char): `O` (stdout) or `E` (stderr).
- **line_type** (optional): `+` if continuation of the previous line, absent for new lines.

Examples: `00O` (runner stdout, new line), `01E` (script stderr, new line), `00O+` (runner stdout, continuation).

## Section markers

Collapsible section markers embedded in the log stream:

```
\e[0Ksection_start:<unix_timestamp>:<name>[options]\r\e[0K
\e[0Ksection_end:<unix_timestamp>:<name>\r\e[0K
```

Names may only contain letters, numbers, `_`, `.`, `-`. The `[collapsed=true]` option makes sections collapsed by default. The `\e[0K` (clear to end of line) sequences prevent markers from appearing in the rendered UI.

## Other notes

- Lines often end with `\r\n` rather than just `\n`, especially around section markers.
- ANSI color codes appear both with ESC prefix (`\e[32;1m`) and bare (`[32;1m`, typically after `[0K` sequences).
- `[0K` (clear to end of line) appears frequently, sometimes with and sometimes without the `\e` prefix.

## References

- [GitLab Docs: Job log timestamps](https://docs.gitlab.com/ci/jobs/job_logs/#job-log-timestamps) — `FF_TIMESTAMPS` feature flag
- [GitLab Docs: Collapsible sections](https://docs.gitlab.com/ci/jobs/job_logs/#expand-and-collapse-job-log-sections) — section marker format
- [GitLab MR !153516](https://gitlab.com/gitlab-org/gitlab/-/merge_requests/153516) — Ansi2Json timestamp parsing, defines the stream header format
- [GitLab Runner #36888](https://gitlab.com/gitlab-org/gitlab-runner/-/issues/36888) — "Add stream information per log line" feature
