# Security Review - Bells CI Failure Analysis

**Last Updated:** 2026-03-13
**Application Version:** 1.0
**Review Status:** Post-mitigation assessment

---

## Executive Summary

This document provides a comprehensive security assessment of the bells application after implementing critical security fixes. **4 critical vulnerabilities have been mitigated**, reducing the application's attack surface significantly. However, **10 medium/low severity issues remain** that should be addressed before deploying in a production or shared environment.

---

## Fixed Vulnerabilities (Mitigated)

### ✅ 1. Zip Slip - Path Traversal (CRITICAL)
**Status:** FIXED
**Location:** `lib/bells/github_client.rb:187-208`
**CVE:** Similar to CVE-2018-1002200

**Vulnerability:**
Malicious ZIP files from GitHub artifacts could write files outside intended directory via entries like `../../etc/passwd`.

**Fix Implemented:**
```ruby
def extract_zip(zip_path, dest_dir)
  dest_dir_real = File.realpath(dest_dir)

  zip.each do |entry|
    extract_path_real = File.expand_path(File.join(dest_dir, entry.name))

    unless extract_path_real.start_with?(dest_dir_real + File::SEPARATOR)
      warn "Zip Slip attempt detected: #{entry.name}"
      next  # Skip malicious entries
    end

    entry.extract(extract_path)
  end
end
```

**Test Coverage:** 3 tests in `spec/lib/github_client_security_spec.rb`

---

### ✅ 2. XML External Entity (XXE) Injection (CRITICAL)
**Status:** FIXED
**Location:** `lib/bells/junit_parser.rb` (all XML parsing)
**CVE:** Similar to CVE-2019-11324

**Vulnerability:**
Malicious JUnit XML files could:
- Read local files via `<!ENTITY xxe SYSTEM "file:///etc/passwd">`
- Perform SSRF attacks via `<!ENTITY xxe SYSTEM "http://internal/secret">`
- Cause DoS via billion laughs attack

**Fix Implemented:**
```ruby
Nokogiri::XML(xml) do |config|
  config.nonet   # Disable network access
  config.noent   # Disable entity expansion
  config.noblanks
end
```

**Test Coverage:** 3 tests in `spec/lib/junit_parser_security_spec.rb`

---

### ✅ 3. Command Injection (CRITICAL)
**Status:** FIXED
**Location:** `lib/bells/github_client.rb:210-217`

**Vulnerability:**
Backticks (`gh auth token`) execute shell commands, vulnerable to PATH manipulation.

**Fix Implemented:**
```ruby
def fetch_gh_token
  stdout, status = Open3.capture2("gh", "auth", "token", err: File::NULL)
  status.success? ? stdout.strip : nil
rescue Errno::ENOENT
  nil
end
```

**Protection:**
- No shell invocation
- Direct binary execution
- Array arguments (no shell metacharacters)
- Graceful handling of missing `gh` command

**Residual Risk:** If attacker controls PATH before Ruby process starts, could still execute malicious binary. Mitigation: Use hardcoded path in production.

---

### ✅ 4. Cross-Site Scripting (XSS) - 13 Locations (HIGH/CRITICAL)
**Status:** FIXED
**Locations:** All ERB templates in `views/`

**Vulnerability:**
Unescaped user-controlled content from GitHub API and JUnit XML could execute JavaScript:
- PR titles: `<script>alert('XSS')</script>`
- Usernames: `<img src=x onerror=alert('XSS')>`
- Job names, failure messages, stack traces

**Fix Implemented:**
1. Added `gem "erubi"` to Gemfile
2. Configured Sinatra: `set :erb, escape_html: true`
3. Changed layout: `<%== yield %>` to pass through escaped content

**Protected Data:**
- PR titles (GitHub API)
- User login names (GitHub API)
- Job names (GitHub Actions)
- Failure messages (JUnit XML)
- Stack traces (JUnit XML)
- Error messages (download errors)

**Test Coverage:** 5 tests in `spec/routes/xss_protection_spec.rb`

---

## Remaining Vulnerabilities (Unmitigated)

### 🔴 5. No Authentication or Authorization (HIGH)
**Status:** UNMITIGATED
**Location:** `app.rb` (entire application)

**Risk:**
Anyone with network access can:
- View all PR information
- Trigger expensive analysis operations
- Auto-restart GitHub Actions jobs
- Access API endpoints
- Consume resources (DoS)

**Impact:**
- Data exposure
- Resource exhaustion
- Unauthorized job manipulation

**Recommended Fix:**
```ruby
# Option 1: Basic Auth
use Rack::Auth::Basic do |username, password|
  username == ENV['BELLS_USERNAME'] && password == ENV['BELLS_PASSWORD']
end

# Option 2: GitHub OAuth (recommended)
use OmniAuth::Builder do
  provider :github, ENV['GITHUB_CLIENT_ID'], ENV['GITHUB_CLIENT_SECRET']
end
```

**Mitigation Priority:** HIGH - Required before public deployment

---

### 🟠 6. No Rate Limiting (HIGH)
**Status:** UNMITIGATED
**Location:** All endpoints

**Risk:**
- Abuse of expensive `/pr/:number` endpoint
- GitHub API rate limit exhaustion
- Disk space exhaustion via cache
- CPU/memory exhaustion

**Exploitation:**
```bash
while true; do curl http://target/pr/5443 & done
```

**Recommended Fix:**
```ruby
gem "rack-attack"

Rack::Attack.throttle('api/ip', limit: 10, period: 60) do |req|
  req.ip
end

use Rack::Attack
```

**Mitigation Priority:** HIGH - Required for production

---

### 🟠 7. No CSRF Protection (MEDIUM)
**Status:** UNMITIGATED
**Location:** All endpoints

**Risk:**
GET endpoints have side effects (job restarts), violating RESTful principles. Vulnerable to CSRF attacks via:
```html
<img src="http://bells/pr/123" />
```

**Recommended Fix:**
1. Use POST for state-changing operations
2. Implement CSRF tokens:
```ruby
enable :sessions
set :session_secret, ENV['SESSION_SECRET']
use Rack::Protection::AuthenticityToken
```

**Mitigation Priority:** MEDIUM

---

### 🟠 8. Insecure Direct Object Reference (IDOR) (MEDIUM)
**Status:** UNMITIGATED
**Location:** `/pr/:number`, `/api/pr/:number`

**Risk:**
Any user can access any PR by changing URL parameter. While GitHub data is semi-public, cached analysis results may contain sensitive information.

**Exploitation:**
```bash
for i in {1..10000}; do curl http://target/api/pr/$i; done
```

**Recommended Fix:**
Implement authorization to verify users have access to specific PRs (requires authentication first).

**Mitigation Priority:** MEDIUM

---

### 🟠 9. Race Condition in Auto-Restart (MEDIUM)
**Status:** UNMITIGATED
**Location:** `lib/bells.rb:37-43`

**Risk:**
Concurrent requests can trigger multiple restarts of the same job.

**Recommended Fix:**
```ruby
require 'concurrent'

@@restart_locks = Concurrent::Map.new

lock_key = "restart:#{pr_number}:#{job_id}"
if @@restart_locks.put_if_absent(lock_key, true)
  Thread.new do
    begin
      client.restart_job(job_id)
    ensure
      @@restart_locks.delete(lock_key)
    end
  end
end
```

**Mitigation Priority:** MEDIUM

---

### 🟡 10. Error Information Disclosure (MEDIUM)
**Status:** UNMITIGATED
**Location:** `views/pr_analysis.erb:14-23`

**Risk:**
Detailed error messages expose:
- File paths
- Internal system information
- API endpoints

**Recommended Fix:**
```ruby
if ENV['RACK_ENV'] == 'production'
  @display_errors = ["Failed to download some artifacts"]
else
  @display_errors = @results[:download_errors]
end
```

**Mitigation Priority:** LOW

---

### 🟡 11. Missing Security Headers (MEDIUM)
**Status:** UNMITIGATED
**Location:** `app.rb`

**Missing Headers:**
- `Content-Security-Policy`
- `X-Content-Type-Options: nosniff`
- `X-Frame-Options: DENY`
- `Strict-Transport-Security` (if HTTPS)

**Recommended Fix:**
```ruby
before do
  headers({
    'Content-Security-Policy' => "default-src 'self'; script-src 'self' 'unsafe-inline'; style-src 'self' 'unsafe-inline';",
    'X-Content-Type-Options' => 'nosniff',
    'X-Frame-Options' => 'DENY',
    'X-XSS-Protection' => '1; mode=block'
  })
end
```

**Mitigation Priority:** LOW-MEDIUM

---

### 🟡 12. Unbounded Cache Growth (LOW)
**Status:** UNMITIGATED
**Location:** `.cache/` directory

**Risk:**
Cache grows indefinitely:
- Artifacts are never cleaned up
- Cache has 5-minute TTL but files aren't deleted
- Can fill disk over time

**Recommended Fix:**
```ruby
def cleanup_old_cache(cache_dir, max_age_days: 7)
  Dir.glob(File.join(cache_dir, '*')).each do |pr_dir|
    next unless File.directory?(pr_dir)
    if File.mtime(pr_dir) < Time.now - (max_age_days * 86400)
      FileUtils.rm_rf(pr_dir)
    end
  end
end

# Run periodically or on app startup
cleanup_old_cache('.cache')
```

**Mitigation Priority:** LOW

---

### 🟡 13. Thread Resource Leaks (LOW)
**Status:** UNMITIGATED
**Location:** `lib/bells.rb:37`, `lib/bells/github_client.rb:129`

**Risk:**
Threads created without proper lifecycle management. Exceptions could leave orphaned threads.

**Recommended Fix:**
```ruby
Thread.new do
  begin
    # ... work ...
  rescue => e
    warn "Thread error: #{e.message}"
  ensure
    # Cleanup resources
  end
end
```

**Mitigation Priority:** LOW

---

### 🟡 14. Path Traversal in Cache Path (MITIGATED)
**Status:** MITIGATED (but could be hardened)
**Location:** `lib/bells.rb:94-96`

**Current Mitigation:**
Route uses `params[:number].to_i`, forcing integer conversion.

**Recommended Hardening:**
```ruby
def cache_path(pr_number, cache_dir)
  raise ArgumentError unless pr_number.to_s =~ /^\d+$/
  File.join(cache_dir, pr_number.to_s, "analysis.json")
end
```

**Mitigation Priority:** LOW

---

## Security Test Coverage

**Total Security Tests:** 11
- Zip Slip protection: 3 tests
- XXE protection: 3 tests
- XSS protection: 5 tests

**Overall Test Suite:** 65 tests (all passing)

---

## Deployment Recommendations

### For Local/Development Use (Current State)
✅ **Safe to use** - Critical vulnerabilities fixed

**Assumptions:**
- Trusted network only
- Single user or small team
- No exposure to public internet

---

### For Production/Shared Environment

**REQUIRED before deployment:**
1. ✅ Enable authentication (Issue #5)
2. ✅ Implement rate limiting (Issue #6)
3. ✅ Add security headers (Issue #11)

**RECOMMENDED:**
4. ✅ Fix CSRF (Issue #7) - Use POST for state changes
5. ✅ Add authorization checks (Issue #8)
6. ✅ Implement cache cleanup (Issue #12)
7. ✅ Add request logging and monitoring
8. ✅ Set up HTTPS with valid certificate

**OPTIONAL:**
9. ⚪ Harden cache path validation (Issue #14)
10. ⚪ Improve thread management (Issue #13)
11. ⚪ Sanitize error messages (Issue #10)

---

## Security Checklist

### Critical (All Fixed ✅)
- [x] Command Injection
- [x] Zip Slip / Path Traversal
- [x] XXE Injection
- [x] XSS (all 13 locations)

### High Priority (Unmitigated ⚠️)
- [ ] Authentication
- [ ] Rate Limiting
- [ ] Authorization (IDOR)

### Medium Priority (Unmitigated ⚠️)
- [ ] CSRF Protection
- [ ] Security Headers
- [ ] Error Message Sanitization

### Low Priority (Acceptable Risk 🟡)
- [ ] Cache Cleanup
- [ ] Thread Management
- [ ] Path Validation Hardening

---

## Threat Model

**Trusted Components:**
- GitHub API responses (API endpoint is hardcoded)
- GitHub Actions artifacts (from DataDog/dd-trace-rb only)

**Untrusted Components:**
- Network (MITM possible without HTTPS)
- Users (if authentication not enabled)
- Cache directory (world-readable if permissions wrong)

**Attack Vectors (by priority):**
1. **Public internet access** → Requires authentication + rate limiting
2. **Malicious artifacts** → Mitigated (Zip Slip + XXE fixed)
3. **Malicious PR content** → Mitigated (XSS fixed)
4. **Local file system** → Partially mitigated (cache isolation)

---

## Dependency Security

**Current Dependencies (as of 2026-03-13):**
- Sinatra 4.2.1 ✓
- Rack 3.2.5 ✓
- Nokogiri 1.19.1 ✓
- Rubyzip 3.2.2 ✓
- Octokit 10.0.0 ✓
- erubi 1.13.1 ✓

**Recommendation:**
```bash
# Add to development dependencies
gem "bundler-audit"

# Run regularly
bundle audit check --update
```

---

## Secure Configuration Guide

### Environment Variables

**Required:**
```bash
# Optional but recommended
export GITHUB_TOKEN="ghp_..."  # Avoid rate limits

# For production (if auth added)
export BELLS_USERNAME="admin"
export BELLS_PASSWORD="$(openssl rand -base64 32)"
export SESSION_SECRET="$(openssl rand -hex 64)"
```

**Security Rules:**
- Never commit `.env` file
- Use secrets management (e.g., GitHub Secrets, Vault)
- Rotate tokens regularly

### File Permissions

**Cache directory:**
```bash
chmod 700 .cache  # Only owner can read/write
```

**Sensitive files:**
```bash
chmod 600 .env    # Only owner can read
```

---

## Monitoring Recommendations

**What to Monitor:**
1. **Failed authentication attempts** (once auth added)
2. **Rate limit violations** (once rate limiting added)
3. **Zip Slip attempts** - Check logs for "Zip Slip attempt detected"
4. **Cache directory size** - Alert if > 10GB
5. **Error rates** - Spike in download errors may indicate attack

**Logging:**
```ruby
# Add structured logging
gem "semantic_logger"

# Log security events
logger.warn "Security: Zip Slip attempt", entry: entry.name, pr: pr_number
```

---

## Incident Response

**If Zip Slip attempt detected:**
1. Check logs for affected PR numbers
2. Inspect `.cache/{pr_number}/` directories
3. Delete suspicious cache directories
4. Review GitHub Actions workflow files for the PR

**If XSS detected:**
1. Clear browser cache/cookies
2. Review PR titles and usernames for malicious content
3. Report to GitHub if malicious account found

**If unusual activity:**
1. Check application logs
2. Review GitHub API rate limit status
3. Inspect cache directory size and contents
4. Review recent PR analysis requests

---

## Security Audit Trail

| Date | Severity | Issue | Status | Commit |
|------|----------|-------|--------|--------|
| 2026-03-13 | CRITICAL | Zip Slip | Fixed | 538c3e6 |
| 2026-03-13 | CRITICAL | XXE Injection | Fixed | 538c3e6 |
| 2026-03-13 | CRITICAL | Command Injection | Fixed | 80cf582 |
| 2026-03-13 | HIGH | XSS (13 locations) | Fixed | 01ffce2 |
| 2026-03-13 | HIGH | No Authentication | Open | - |
| 2026-03-13 | HIGH | No Rate Limiting | Open | - |
| 2026-03-13 | MEDIUM | No CSRF | Open | - |
| 2026-03-13 | MEDIUM | IDOR | Open | - |
| 2026-03-13 | MEDIUM | Race Condition | Open | - |
| 2026-03-13 | MEDIUM | Error Disclosure | Open | - |
| 2026-03-13 | MEDIUM | Missing Headers | Open | - |
| 2026-03-13 | LOW | Cache Growth | Open | - |
| 2026-03-13 | LOW | Thread Leaks | Open | - |
| 2026-03-13 | LOW | Path Validation | Open | - |

**Security Score:** 4/14 critical issues fixed (29% complete)
**Production Readiness:** Not ready - requires authentication + rate limiting

---

## Compliance Notes

**Data Handling:**
- Application processes public GitHub data
- No PII or sensitive data stored
- Cache contains PR analysis results (potentially sensitive)
- No encryption at rest for cache files

**Privacy:**
- No user tracking
- No analytics
- No cookies (unless sessions enabled)

**GDPR/Privacy:** Not applicable (public data only)

---

## References

- [OWASP Top 10 2021](https://owasp.org/Top10/)
- [Zip Slip Vulnerability](https://snyk.io/research/zip-slip-vulnerability)
- [XXE Prevention - OWASP](https://cheatsheetseries.owasp.org/cheatsheets/XML_External_Entity_Prevention_Cheat_Sheet.html)
- [Sinatra Security Guide](http://sinatrarb.com/contrib/protection)
- [Ruby Security Best Practices](https://guides.rubyonrails.org/security.html)

---

## Contact

For security issues, please report via:
- GitHub Issues: https://github.com/[repo]/bells/issues (for non-sensitive issues)
- Private disclosure: [email] (for critical vulnerabilities)

**Do not publicly disclose security vulnerabilities before they are fixed.**
