# Analysis: Why "Ruby 2.6 / batch" is Uncategorized

## Summary

The job "Ruby 2.6 / batch" (and all similar "/ batch" jobs) are being categorized as "uncategorized" instead of "tests" because the job name doesn't match any existing category patterns.

## Current Categorization Pattern for Tests

```ruby
[:tests, %r{test|spec|build & test|parametric|end-to-end|junit}i]
```

The pattern matches: `test`, `spec`, `build & test`, `parametric`, `end-to-end`, `junit`

## The Problem

**Job naming pattern in dd-trace-rb:**
- `Ruby 2.6 / batch`
- `Ruby 2.7 / batch`
- `JRuby 9.2 / batch`
- etc.

These jobs:
1. Use the `_unit_test.yml` workflow (confirmed in logs)
2. Are test jobs that run unit tests
3. Have names ending in "/ batch" without the word "test" or "spec"

The word **"batch"** refers to running tests in batches for parallelization. Each Ruby/JRuby version has:
- One "/ batch" job - likely a job that coordinates or prepares test batches
- Multiple "/ build & test" jobs with batch numbers: `[0]`, `[1]`, `[2]`, etc.

## Evidence from Logs

```
2026-03-12T03:05:15.8874837Z Uses: DataDog/dd-trace-rb/.github/workflows/_unit_test.yml@refs/pull/5431/merge
2026-03-12T03:05:15.8882830Z Complete job name: Ruby 2.6 / batch
```

The job explicitly uses `_unit_test.yml`, confirming it's a test job.

## Impact

In PR 5431, there are **multiple "/ batch" jobs** across different Ruby versions that are all uncategorized:
- Ruby 2.5 / batch
- Ruby 2.6 / batch
- Ruby 2.7 / batch
- Ruby 3.0 / batch
- Ruby 3.1 / batch
- Ruby 3.2 / batch
- Ruby 3.3 / batch
- Ruby 3.4 / batch
- Ruby 4.0 / batch
- JRuby 9.2 / batch
- JRuby 9.3 / batch
- JRuby 9.4 / batch

## Solution

Add `batch` to the tests category pattern:

```ruby
[:tests, %r{test|spec|build & test|parametric|end-to-end|junit|batch}i]
```

This will correctly categorize all "/ batch" jobs as test jobs.
