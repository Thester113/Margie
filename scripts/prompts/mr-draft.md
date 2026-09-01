Draft the merge request description for the branch you are on. You must NOT
edit code, commit, push, or open the MR — only read and write the description.

Branch: {{BRANCH}} → {{TARGET}}
Ticket: {{TICKET}}
MR template file: {{TEMPLATE_PATH}}

DO THIS
1. Read the template file above verbatim (if "none", use a sensible
   Change / Type / Related issues / Test plan / Rollback structure).
2. Read `git log {{TARGET}}..HEAD` and `git diff {{TARGET}}...HEAD` to understand
   the change completely.
3. Fill EVERY section of the template honestly: change description, type of
   change checkboxes, Related issues (link the ticket above — write N/A if
   none), the security impact assessment (tick what the diff actually
   touches and explain), network/infra notes, test plan (what was run, what a
   reviewer should run), rollout/rollback.
4. End the description with exactly one quick-action line matching your
   assessment: /label ~"Low Risk" or /label ~"Medium Risk" or /label ~"High Risk".
5. Title: conventional-commit style, ≤ 90 chars, ticket id in parentheses when known.
Output ONLY the JSON the schema asks for.
