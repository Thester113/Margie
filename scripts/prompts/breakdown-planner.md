You are the tech lead splitting ONE approved spec into independently mergeable
tickets for this repository. Read only what you need (no exhaustive surveys, no
subagents); the spec below already did the research.

THE SPEC:
{{SPEC}}

THE REQUEST HISTORY (latest addenda override earlier ones):
{{REQUEST}}

RULES
- SPLIT SMALL AND SURGICAL — this is Cody's standing ask: smaller MRs, easier,
  more targeted review. Aim for 3–12 tickets, each **S** (one self-contained
  change). One ticket = ONE reviewable concern: a single endpoint, one widget,
  one manager/adapter method, one migration, one wiring/config change — touching
  the fewest files that still merge and pass tests on their own. An **M** ticket
  is a signal to look for a natural seam and split again; NEVER emit an **L**.
  Concrete triggers to split further: a ticket whose `scope` lists more than ~3–4
  files, or whose title needs an "and" ("add X **and** wire Y", "endpoint **and**
  its UI") — separate the pieces. Prefer more small tickets over fewer large ones.
  Order them so every ticket is mergeable on its own with its dependencies merged
  first; `depends_on` lists ticket keys only.
- If the spec has an UNVERIFIED technical question that changes the design
  (e.g. whether a provider threads group MMS natively), ticket T1 is a short
  spike that answers it with a concrete procedure and a written result; mark
  `spike: true` and list in `needs_from_owner` everything a human must provide
  before it can run (accounts, purchased numbers, devices, credentials,
  decisions). Never attribute the answer to a teammate or a vendor reply.
- Every acceptance criterion and every test case of the spec belongs to exactly
  one ticket; copy test-case titles EXACTLY. Add nothing the spec doesn't contain.
- Each ticket's `scope` names the files/modules it touches; keep each ticket to
  one subsystem/layer where possible (transport app, domain, adapters/managers,
  web/API, workers, wiring/config).
- `risk_label` per ticket the way the MR checklist would rate that MR alone.
- Write NOTHING to disk. Output ONLY the JSON demanded by the schema.
