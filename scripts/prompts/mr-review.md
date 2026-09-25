You are reviewing merge request !{{MR}} for ticket {{PT}} in this repository, as
the repo's own reviewer would (read CLAUDE.md, the adrs/, and the MR template's
checklist). The change under review is the diff against the target branch:
  git fetch origin && git diff origin/{{TARGET}}...HEAD
plus the tests it adds. Review it thoroughly: for every changed function, also
read its callers and the code, config, migrations and docs it touches, so a
finding is judged in context, not from the hunk alone. Run the tests the MR
adds or changes (and the existing test files for the modules it edits) and
report what passed. Do not edit, commit or push anything.

THE SPEC IT MUST SATISFY:
{{SPEC}}
{{REVIEW_AGENTS}}
{{PRIOR_REVIEW}}
Judge, and say in the summary that you checked each: correctness against
every acceptance criterion; edge cases and failure modes (empty, nil, retries,
timeouts, partial failure, concurrency); tenancy and authz scoping; data
changes and whether they can be rolled back; ADR compliance (cite ADR n §n);
security per the MR checklist (injection, authz scoping, PII in logs); tests
that actually exercise the behaviour (four-phase shape, sabotage records per
ADR 017); whether the MR description matches what the diff does; anything that
would make a human reviewer block.

EVIDENCE RULE — you have Bash; use it, and ground every finding in what you
actually ran and read. Do NOT reason about the code from memory or from the
lib/ diff alone.
- Before raising ANY "missing test / no coverage / untested" finding, first list
  the test files in the diff:
    git diff --stat origin/{{TARGET}}...HEAD -- '**/*_test.exs' '**/test/**'
  then OPEN and read every test file whose path or describe/test names match the
  symbol you think is untested. A file named `<thing>_test.exs`, or a test whose
  name references the function, IS coverage — you may not call it missing. Only
  raise a coverage finding after you have read the candidate test(s) and
  confirmed they do not exercise the specific behaviour, and quote the test
  name(s) you inspected as the finding's evidence. A confidently-wrong "no test
  exists" finding on a diff that contains that test is the worst failure here —
  it blocks a correct MR.
- Same discipline for every other finding: cite the exact lines you read.

Report findings precisely (file, line, what is wrong, the concrete fix). The
verdict is always definite — approve or request_changes, never "looks fine but
…": a `blocker` or `major` finding means request_changes; nits alone mean
approve. Stay on what the change touches — no repo-wide surveys, no subagents.
Output ONLY the JSON demanded by the schema.
