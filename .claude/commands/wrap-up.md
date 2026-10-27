---
description: "End the session: commit code on its branch, rewrite docs/STATUS.md, add the CHANGELOG line, file spec interpretations under Needs Adam, commit the status documents on main"
allowed-tools: Bash(git status:*), Bash(git branch:*), Bash(git log:*), Bash(git diff:*), Bash(git show:*), Bash(git add:*), Bash(git commit:*), Bash(git merge:*), Bash(git push:*), Bash(git worktree:*), Bash(git -C:*), Bash(swift test:*), Read, Edit, Write, Grep, Glob
---

End this session the way `CLAUDE.md` ("Session contract") requires. Do the steps in order.
If a step cannot be done, stop and say which one and why; never skip ahead to the commit.

## Where things stand

- Branch: !`git branch --show-current`
- Working tree: !`git status --short`
- Recent history: !`git log --oneline --all --decorate -8`
- Main checkout: !`git -C ~/Developer/project-o status --short --branch`
- The current page, which step 5 replaces: @docs/STATUS.md

## Steps

### 1. Account for the session

Say, in a few lines: which area and branch this session worked on, which spec sections it
touched, whether the area reached review (its brief follows in step 9), and whether
`swift test` is green.
If any code changed and the tests have not run since, run `swift test` now. If it is red,
stop here and report the failures; nothing below may describe red code as done.

### 2. Commit the code on its branch

Code and tests belong on the area's `area/<name>` branch. Commit anything uncommitted
there now, in small commits that name the spec section (`Spec 3 §5 — the live pointer`),
and push the branch if a remote exists. Leave the status documents uncommitted: they go
to `main` in step 8. Never commit code on `main`, and never commit a status document on
the area branch.

### 3. Collect the spec interpretations

List every place this session chose a reading where the spec left room, or departed from
the spec's letter. For each: the spec section, what it left open, what was chosen, and the
alternative. These are the same items the brief's *Spec interpretations* heading carries
(`CLAUDE.md`, "Working in Nimbalyst"), so the two never disagree. If there are none, say
so.

### 4. Reach `main` through the main checkout

Sessions run in Nimbalyst worktrees, so `main` is checked out in the main folder,
`~/Developer/project-o`, and `git checkout main` is refused here. Do not try it. The
status documents reach `main` one of two ways:

- **Area session** (the branch carries code): write each status document from steps 5–7
  into the main checkout by absolute path, under `~/Developer/project-o/`, and commit
  there in step 8 with `git -C ~/Developer/project-o`. The copies in this worktree stay
  untouched, so the area branch never carries a status document and the merge on
  `approved` has nothing to resolve.
- **Docs-only session** whose branch holds nothing but status documents on top of
  `main`: edit here, commit here in step 8, then fast-forward `main` with
  `git -C ~/Developer/project-o merge --ff-only <branch>`.

First run `git -C ~/Developer/project-o status --short`. If a status document is already
modified there, stop and say so; never overwrite another session's uncommitted work.

### 5. Rewrite `docs/STATUS.md`

Rewrite the whole file from the current truth, not by patching lines. Keep this shape:

- **Intro**: a few lines on what the page is and where the detail lives.
- **Areas**: a table `# | Area | Spec | State | Last session, or what is left`, every v1
  area from `docs/build-order.md` plus one row each for v1.5 and v2. State is one of
  `not started`, `in progress`, `brief waiting for approval`, `merged`. An area whose spec
  is unwritten is `not started` with "Spec needed first" in the last column. The last
  column is one line: what the last session did on that area, or what is left before it
  can move.
- **Now**: one short paragraph: the live area, its branch, where the last session stopped,
  and what is and is not on `main`.
- **Needs Adam**: three lists. *Briefs waiting for approval*, each with where the brief
  is (the area's session), the decisions it asks for and the recommended answer. *Spec
  interpretations made so far*, a table `Spec | Left open | Chosen | Alternative`, with
  this session's items added. *Spec corrections proposed*, one line each: what the spec
  says, what the code does, the fix.
  An item leaves these lists only when Adam has answered it; the area's session keeps the
  brief as the record.
- **Next**: the next area, its branch, and its prompt copied verbatim from
  `docs/build-order.md` (the common preamble block and the area's own block, unchanged).
  Then one short note on which later areas could start independently and what they wait
  for.

No percentages and no counts anywhere: no "N of M areas", no test counts, no "24 rows".
Spec section numbers, row numbers and area numbers are names, not counts.

### 6. Append the CHANGELOG line

Add one line at the top of `## Unreleased` in `CHANGELOG.md`: the date, what the session
did, the branch it is on, and what comes next. An area that reached review or shipped gets
its area line; any other session gets a docs or tooling line.

### 7. Flip the area's status in `docs/build-order.md`

Only if it changed: `in progress` when the first code session starts an area, `in review`
when the brief is written, `shipped` only after Adam's `approved` and the merge. Never
`shipped` on your own judgement.

### 8. Commit on `main`

Stage only status documents, by path, in the checkout step 4 chose: `docs/STATUS.md`,
`CHANGELOG.md`, `docs/build-order.md`, and `CLAUDE.md` if the session changed it. Never
`git add -A` or `git add .`. Commit as `Status: Area N — <one line>`, or
`Status: docs — <one line>` for a session without an area, with the attribution line this
session uses. A docs-only session then fast-forwards `main` (step 4). Do not push `main`
unless Adam asked for it this session.

### 9. Print `docs/STATUS.md`, then the brief

Print the whole of `docs/STATUS.md`, after one line naming the commit and the branch the
code is on. If this session brought an area to review, the brief follows as the final
message, under the four headings in `CLAUDE.md` ("Working in Nimbalyst"); otherwise the
status page is the last thing you say.
