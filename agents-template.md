# Agent Operating Rules

This file defines how agents must behave in this repository.
These rules apply to all tickets and all work.

---

## Before Starting Any Work

1. Read `progress.md` (create if missing).
2. Determine the next incomplete ticket from the Execution Order below.
3. Check if a branch already exists for that ticket.
4. Resume from where `progress.md` left off.

---

## Discovery Before Coding

Before writing any code for a ticket:

1. Read the ticket's reference files section (if present).
2. Open each referenced file and study the pattern (naming, imports, structure).
3. Only start coding after you can describe the pattern you will follow.

---

## Tickets

<!-- CUSTOMISE: List your tickets here in execution order -->
<!-- Each ticket should be a markdown file in a tickets/ directory -->

- Tickets live in the `tickets/` folder as markdown files.
- Each ticket is a PRD for one unit of work.
- Work on exactly ONE ticket at a time. Use this Execution Order:
  1. **ticket-1** — Description of first task
  2. **ticket-2** — Description of second task
  3. **ticket-3** — Description of third task
- Do not switch tickets unless explicitly instructed.

---

## Branches

- Branch name format: `<ticket-id>-<slug>` (example: `ticket-1-add-user-model`)
- Create feature branches from the base branch (the branch you are currently on).
- After completing a ticket, merge the feature branch back into the base branch.
- Never push to a remote unless explicitly instructed.

### Branch Workflow

1. From the base branch: `git checkout -b <ticket-branch>`
2. Develop and commit on the feature branch.
3. Run verification on the feature branch (dependencies are installed).
4. When ready, merge back: `git checkout <base-branch> && git merge -m "merge: <ticket-branch> into <base-branch>" <ticket-branch>`
5. Run verification again on the base branch after merge.

---

## Human-Assisted Tickets

- Some tickets may require manual operations that cannot be automated.
- When encountering these, skip the ticket, note it in progress.md, and continue to the next ticket.

---

## Change Discipline

- Prefer small, incremental changes.
- Make one focused change per iteration.
- Do not change behaviour unless explicitly stated in the ticket.
- Do not introduce new dependencies unless approved.

---

## Verification

<!-- CUSTOMISE: Replace with your project's actual commands -->

- Tests are the source of truth.
- Verification runs on the **feature branch** during development and on the **base branch** after merging.

### Verification Commands

- **Lint:** `npm run lint`
- **Type check:** `npm run typecheck`
- **Tests:** `npm test`

### Verification Workflow

1. Write code and commit on the feature branch.
2. Run verification on the feature branch.
3. If verification passes: merge into the base branch and run verification again.
4. If verification fails on the feature branch: fix, commit, and re-run. Max 3 attempts.
5. After merging, if verification fails on the base branch: fix directly on the base branch, commit, and re-run. Max 3 attempts.
6. If stuck after 3 attempts, stop and say:
   "Blocked on [ticket]. Issue: [description]. Awaiting human input."

- Prefer running the smallest applicable verification first
  (e.g. single-file test before full test suite).
- Never skip a failing test to proceed.

---

## Commits

- Commit frequently as you complete logical units of work.
- Format: `<prefix>: <what changed>`
- Allowed prefixes: `feat`, `fix`, `refactor`, `test`, `docs`, `chore`, `style`, `perf`, `ci`, `merge`, `wip`
- Example: `feat: add user authentication middleware`
- **Merge commits MUST also use the prefix format.** Git's default `Merge branch 'X' into Y` message may be rejected by pre-receive hooks.
  - Use: `git merge -m "merge: <branch> into <target>" <branch>`
- Never push unless instructed.

---

## Progress Tracking

- A file named `progress.md` must exist.
- After every successful iteration (tests pass or verification succeeds),
  update `progress.md` automatically.
- Each entry must include (briefly):
  - What was changed
  - Why it was changed
  - Any important decisions
  - Anything to avoid repeating
- **Always end `progress.md` with a `## Next Steps` section** that describes:
  - Which ticket is next (or the current ticket if still in progress)
  - The exact step to resume from
  - Any blockers or prerequisites
- This section is critical for session continuity — a fresh session must be able to read `progress.md` and know exactly what to do next.
- Keep entries short, chronological, and easy to scan.

---

## Merging

- After a ticket passes all verification, merge its branch into the base branch.
- Since you are running in AFK (unattended) mode, auto-approve merges — do NOT wait for human confirmation.

---

## Completion

1. When all code changes are committed on the feature branch, run verification.
2. If verification passes, merge into the base branch.
3. Run verification on the base branch.
4. Update `progress.md` with a summary of the work done.
5. **STOP here. Do not start the next ticket.** The next iteration of the loop will pick it up.

- When ALL tickets are complete and verified, output exactly:

  <promise>COMPLETE</promise>
