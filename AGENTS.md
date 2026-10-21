# Agent guidelines

## No slop

Everything you write into this repo should be as short as it can be while staying clear. That covers code comments, the README and other docs, commit messages, PR descriptions, user-facing strings, and tests. Slop is text that adds length without adding information.

- **Comments** explain a non-obvious *why*: an API quirk, a constraint, a bug being avoided. Don't restate the code, narrate history ("previously…", "now…"), or justify obvious choices. One or two lines is usually enough.
- **Doc comments** only where the name and signature don't already say it. No essays on one-line functions.
- **Docs** say only what their reader needs. The README is for people using the app, CONTRIBUTING for people changing it. Don't repeat the same instructions in both.
- **Messages** (errors, logs, UI copy): one line saying what went wrong and what to do.
- **Tests**: no duplicates, no tests of trivial getters, shared setup in helpers, no comments narrating the test.
- **Code**: no guards for states that can't happen, and no single-use wrappers that only add indirection.
- **Commits**: a single short subject line. Add a body only when the reason isn't evident from the diff.

Match the surrounding code: if a file has few comments, keep it that way.
