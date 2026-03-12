# CI Failure Analysis Design

## Overview

Analyze CI test failures in datadog/dd-trace-rb pull requests by extracting JUnit XML artifacts and presenting aggregated failure data via web interface.

## Requirements

### Data Collection
- Access GitHub Actions workflow runs for a given PR
- Identify failed workflow runs and jobs
- Download JUnit XML artifacts from failed builds
- Parse JUnit XML to extract:
  - Test names (class, method)
  - Failure messages
  - Stack traces
  - Execution time
  - Build context (job name, ruby version, os, etc.)

### Data Aggregation
- Group failures by test identity across multiple builds
- Track failure frequency per test
- Identify flaky tests (intermittent failures)
- Preserve build-specific context for each failure instance
- Handle multiple failure modes of same test

### Presentation
- Web UI to view aggregated failures for a PR
- Show:
  - Failed tests sorted by frequency
  - Failure details (message, stack trace)
  - Which builds/jobs each test failed in
  - Build context for each failure instance
- Filter/search capabilities
- Link back to GitHub Actions logs

### Technical Constraints
- Must work with public and private repos (GitHub auth)
- Handle large PRs with many workflow runs
- Efficient artifact download (some PRs may have 100+ builds)

## Proposed Solution

### Architecture

```
CLI Tool → GitHub API → Artifact Storage → Parser → Web Server → Browser
```

### Components

#### 1. GitHub Integration
- **Tool**: GitHub CLI (`gh`) or Octokit REST API
- **Operations**:
  - List workflow runs for PR
  - Filter for failed runs
  - Download artifacts
- **Auth**: Use existing `gh` authentication or GitHub token

#### 2. Artifact Processing
- **Storage**: Local cache directory (`.bells/cache/<pr-number>/`)
- **Parser**: Ruby XML parser (Nokogiri) or Python (lxml)
- **Data Model**:
```
TestFailure:
  - test_class: string
  - test_name: string
  - failure_message: string
  - stack_trace: string
  - execution_time: float
  - build_context:
    - workflow_name: string
    - job_name: string
    - run_id: int
    - attempt: int
    - os: string
    - ruby_version: string
```

#### 3. Aggregation Engine
- **Input**: List of TestFailure objects
- **Output**: Aggregated view with:
  - Test identity (class + name)
  - Failure count
  - List of failure instances with contexts
  - First/last seen
- **Grouping strategy**: Normalize test names to handle parametrized tests

#### 4. Web Interface
- **Framework**: Lightweight (Sinatra for Ruby, Flask for Python)
- **Features**:
  - Single page per PR analysis
  - Sortable table of failures
  - Expandable rows for details
  - Filter by job type, Ruby version, etc.
  - Export to JSON/CSV
- **Styling**: Minimal CSS, responsive

### Implementation Language

**Ruby**
- Nokogiri for XML parsing
- Sinatra for web interface
- Octokit for GitHub API (or shell out to `gh`)
- Consistent with dd-trace-rb development environment

### CLI Interface

```bash
# Analyze PR
bells analyze-pr <pr-number>

# Start web viewer
bells view <pr-number>

# Clear cache
bells clear-cache <pr-number>
```

### Workflow

1. User runs `bells analyze-pr 1234`
2. Tool fetches workflow runs for PR #1234
3. Identifies failed runs, downloads JUnit artifacts
4. Parses XML files, builds failure database
5. Stores results in `.bells/cache/1234/failures.json`
6. User runs `bells view 1234`
7. Web server starts on localhost:5000
8. Browser displays aggregated failures

### Open Questions

1. **Scope**: Should we analyze all workflow runs or only the latest commit?
2. **Caching**: How long to cache artifacts? Invalidation strategy?
3. **Incremental updates**: Support for updating analysis as new builds complete?
4. **Multi-PR comparison**: Future feature to compare failure patterns across PRs?
5. **GitHub App vs CLI**: Package as GitHub App for in-PR comments vs standalone tool?

### Next Steps

1. Prototype GitHub API integration (list runs, download artifacts)
2. Build JUnit XML parser
3. Design aggregation data structure
4. Create minimal web UI mockup
5. Implement end-to-end for single PR
