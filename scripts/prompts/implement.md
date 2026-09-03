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
  print exactly this line on its own and then stop and wait:
  MARGIE_READY_FOR_QA
  Margie's QA verifier runs automatically. If it passes you will be told
  "QA passed — open the MR" with the prepared description at {{MR_FILE}}; open
  it then with the repo's /merge-request skill and print MARGIE_MR_OPEN <url>.
  The repo's review bots run automatically on the MR's FIRST pipeline only, so
  after opening the MR do NOT push again until that pipeline's review jobs have
  finished (watch it with glab ci status / glab mr view). Anything that must
  cite the MR number (e.g. sabotage records) is pushed after that. Review
  threads then arrive; address every one, push, and resolve the threads you
  fixed — the MR is mergeable only when all threads are resolved. After any
  push, print MARGIE_MR_UPDATED and STOP; never sit polling the pipeline —
  Margie watches it and comes back to you only if something fails.
  If it fails you will be given the findings; fix them, then print
  MARGIE_READY_FOR_QA again.
- If the spec turns out to be wrong or an open question blocks you, say so
  plainly and stop rather than improvising around it.
