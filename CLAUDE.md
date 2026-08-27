# Working conventions for this repo

- **Never end a turn while a PR you created or pushed to has failing or pending CI.** After every
  `git push`/`gh pr create` in this repo, check `gh pr checks <number>` (or poll until the checks
  resolve) before reporting the work as done. If a check is failing, diagnose and fix it — or, if
  it's a known pre-existing flake (see `PROGRESS.md`'s documented flake classes), say so explicitly
  with evidence (a rerun that passed), not just an assumption — before ending the turn. Stated
  directly, 2026-08-27, after ending a turn on PR #30 with a genuinely failing `test` check that
  had not been checked.
