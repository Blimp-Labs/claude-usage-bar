---
document_file: docs/plans/refresh-token.md
mode: plan
revision: 3
reviewed_at: 2026-03-08 16:00
reviewers: [claude, gemini, openai]
verdict: APPROVED
---

# Forge Review - Refresh Token Support Implementation Plan

## Review History

| Iteration | Claude | Gemini | OpenAI | Verdict | Key Issues |
|-----------|--------|--------|--------|---------|------------|
| 1 | MINOR_ISSUES | Ready with fixes | Needs revision | NEEDS_REVISION | Legacy migration flaw, fetchProfile unspecified, task coalescing, retry token, error reporting, test spec |
| 2 | MINOR_ISSUES | APPROVED | Minor revision | NEEDS_REVISION | Compile error in retry, refreshTask defer, isExpired ambiguity |

## Current Iteration (3)

### Claude Inspection

**Scores:** Codebase Grounding: GOOD | Clarity: GOOD | Completeness: ACCEPTABLE | Feasibility: GOOD | Testability: GOOD

**Issues raised:**

1. `init()` update not explicitly called out in plan body — BUT already covered in Teammate 2's prompt ("Update `init()`: use `StoredCredentials.load() != nil`"). Documentation gap, not a missing feature.
2. `coalescedRefresh` completion window — acknowledged as minor inefficiency, not correctness bug.
3. 401 retry uses stale credentials for token rotation — actually handled correctly: the 401 path calls `StoredCredentials.load()` to get fresh credentials from disk.

**Recommendation:** MINOR_ISSUES (no correctness bugs)

### Gemini Inspection

**No critical issues.**

Suggestions: atomic writes, date decoding strategy, token endpoint constant (already exists), logging detail.

**Recommendation:** APPROVED

### OpenAI Inspection

**Issues raised:**

1. Missing test coverage for `validAccessToken()` — the plan already justifies this (requires URLSession mocking which the project doesn't do).
2. `StoredCredentials.load()` swallowing errors — valid suggestion to add logging.
3. `responseTime` placement — already correctly placed before guards in the plan code.

**Recommendation:** Minor suggestions only, no blocking issues.

---

### Consolidated Summary

#### Critical Issues
None. All critical issues from iterations 1 and 2 have been resolved:
- Compile error in retry branch → fixed with `do/catch` (v3 section 7)
- `refreshTask` cleanup → fixed with `defer` (v3 section 5)
- `isExpired` API ambiguity → clarified as public but not used in refresh path (v3 section 1)
- Legacy token migration → fixed with `Date.distantFuture` (v3 section 2)
- `fetchProfile()` 401 handling → fully specified (v3 section 8)
- Task coalescing → `Task<StoredCredentials?, Never>?` with `defer` (v3 section 5)
- Error reporting → `lastError` updated on failures, cleared on success (v3 section 6)
- Permanent token rejection → HTTP 400/401 deletes credentials (v3 section 6)

#### Remaining Suggestions (non-blocking)
- `init()` update should be called out in plan body, not just teammate prompt (Claude)
- Add logging to `StoredCredentials.load()` on decode failure (OpenAI)
- Consider `.completeFileProtection` for atomic writes (Gemini)
- Document TODO for future integration tests covering `coalescedRefresh` (OpenAI)
- `fetchProfile()` could mirror `lastError` updates on refresh failure (OpenAI)

---

### Verdict: APPROVED
