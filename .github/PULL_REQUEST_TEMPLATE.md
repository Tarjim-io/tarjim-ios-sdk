<!--
Title: `type(scope): description`, at most 50 characters — it becomes the squash commit on main.
This repository is public: no keys, hostnames, ticket ids or references to private documents.
-->

## What

<!-- The change in two to four sentences, at the level of behaviour, not files. If this PR
     deliberately leaves something out, say so here. Link the issue: Closes #… -->

## Why

<!-- The problem or requirement. For a fix: the reproduction and the root cause. -->

## Verified

<!-- Exact commands and environments you ran, with their results. Name what is NOT verified and
     what will prove it (the first CI run, a later PR, a manual device run). -->

## Checklist

<!-- Tick what is true; leave a box unticked with the reason. Add a line for anything this PR
     specifically promises (e.g. "The new option is off by default"). -->

- [ ] I added tests to verify the changes.
- [ ] I updated the README and docs if needed.
- [ ] No breaking change for apps using the SDK, or it is called out above.
- [ ] No secret, real hostname or internal reference in the diff (public repository).
- [ ] No new assumption about the server's answers without a fixture that shows it.
