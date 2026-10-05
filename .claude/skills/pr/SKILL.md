---
name: pr
description: Open or update a pull request in this repository — title, body in the What/Why/Verified/Checklist form, the public-repository check, one push per PR. Use whenever a branch is ready for review or a PR body needs rewriting.
---

# Pull requests

The body is for the reviewer and for whoever reads `git log` in a year. It says what changed, why,
and what was actually run — not a list of files or commits.

## Before pushing

1. Scan the diff for anything a public repository must not carry:
   `git diff origin/main...HEAD | grep -niE 'tarjim-[0-9]+-|Signature=|Policy=|staging|TJ-[0-9]|\.env'`
   must print nothing. Hosts other than `*.invalid`, `example.com` and `api.tarjim.io` are a leak.
2. `swift test --parallel` is green, and the "Verified" section below quotes the real result.

## Title

`type(scope): description`, at most 50 characters, imperative — the same rule as a commit message,
because a squash merge makes it the commit on `main`. Types: `feat`, `fix`, `test`, `ci`, `docs`,
`build`, `chore`, `refactor`.

## Body — `.github/PULL_REQUEST_TEMPLATE.md`, four sections

- **What**: two to four sentences on the behaviour change; a reader should know the scope without
  opening the diff. What the PR deliberately leaves out goes here too. `Closes #n` when an issue exists.
- **Why**: the problem or requirement. For a `fix`, the reproduction and root cause, not the symptom.
  For a `feat`, the behaviour in the user's terms.
- **Verified**: every command you ran, where, and its result (`swift test --parallel`: 12/12, Xcode
  26.5; the simulator and OS version for a device run). Name what is NOT verified and what will
  prove it. Never list a check you did not run.
- **Checklist**: five short statements (tests, docs, no breaking change, nothing private, no
  server assumption without a fixture). Tick what is true; leave a box unticked with the reason
  beside it; never delete a line. Add a line for anything this PR specifically promises — "the new
  option is off by default", "the on-disk format is unchanged" — so the reviewer can hold it to that.

Not in a body: a commit list (GitHub shows it), file-by-file narration, review history, how a
decision was made, AI attribution lines or `Co-Authored-By` trailers.

## Open or update

```bash
git push -u origin <branch>                       # one push per PR; none while its CI runs
gh pr create --title "<title>" --body-file <file>  # or --fill-first and edit
gh pr edit <number> --body-file <file>             # rewrite the body after a change
```

After a fix pushed to an open PR, update **Verified** so it describes the branch as it is now.
