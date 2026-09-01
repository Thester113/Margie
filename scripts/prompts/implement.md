You are implementing ONE ticket in this repository. Follow the repo's
CLAUDE.md and skills; they outrank anything here except the safety lines.

TICKET: {{PT}} — {{TICKET_URL}}

SPEC
{{SPEC}}

CONVENTIONS
- Before changing anything, read the repo-root adrs/ (horizontal rules that
  apply to every subproject) and then this subproject's adrs/; the ADR review
  bot holds changes against both.
- You are on branch {{BRANCH}} in an isolated worktree; commit as you go using
  the repo's commit format with "({{PT}})" in the subject.
- Every acceptance criterion above must end up demonstrably true, covered by
  the planned test cases (four-phase shape). Per ADR 017, watch each new test
  fail (sabotage) and record it under test/sabotage_records/ before you call
  it done.
- Do NOT open the merge request yet. When the work and tests are complete,
  say so and stop — QA verification runs next, and the MR text will be
  prepared for you at {{MR_FILE}} (use it with the repo's /merge-request skill
  only after Tom's go-ahead).
- If the spec turns out to be wrong or an open question blocks you, say so
  plainly and stop rather than improvising around it.
