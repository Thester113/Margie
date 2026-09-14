You are hunting for REGRESSIONS in {{OWNER}}'s owned code in this repository — behavior that
used to work and is now broken, bugs introduced by recent changes, and missing test coverage
that would let such a break ship unnoticed. Apply the repo's own reviewer standards (below).

OWNED FILES — review ONLY these (this is {{OWNER}}'s area; do not wander outside it):
{{OWNED}}

Look especially at what changed recently on those paths:
  git log --oneline --since="{{SINCE}}" -- <the owned files above>
  git diff for those commits
and at the tests that cover them.

{{REVIEW_AGENTS}}

EVIDENCE RULE — you have Bash; use it, and ground every regression in what you actually ran and read:
- Do NOT report a regression from a name, a hunch, or the diff alone. Open the file, read the
  code AND its tests.
- Before claiming a behavior is broken: either run the relevant test and quote the FAILURE, or
  give a concrete repro you can defend from the code you read. Before claiming missing coverage:
  list the test files on that path (e.g. `git ls-files '**/*_test.exs' | grep <area>`) and read
  them — a confidently-wrong "no test" or "it's broken" finding is the worst outcome here; it
  churns the fix pipeline. Set confidence: confirmed = you reproduced it; likely = strong code
  evidence; uncertain = you're not sure (drop it unless it's a blocker).
- Report real, current breaks — not style nits. If the worst you can say is a nit, drop it.

For each real regression give: file, line, a one-sentence summary, the evidence you read (quote
it), a concrete repro (or the failing test), the concrete fix, and the confidence.

Be economical — no repo-wide surveys, no subagents. Output ONLY the JSON demanded by the schema.
