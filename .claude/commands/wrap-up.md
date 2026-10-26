---
description: "End the session: commit code on its branch, rewrite docs/STATUS.md, add the CHANGELOG line, file spec interpretations under Needs Adam, commit the status documents on main"
allowed-tools: Bash(git status:*), Bash(git branch:*), Bash(git log:*), Bash(git diff:*), Bash(git show:*), Bash(git add:*), Bash(git commit:*), Bash(git checkout:*), Bash(git push:*), Bash(git worktree:*), Bash(swift test:*), Read, Edit, Write, Grep, Glob
---

End this session the way `CLAUDE.md` ("Session contract") requires. Do the steps in order.
If a step cannot be done, stop and say which one and why; never skip ahead to the commit.

## Where things stand

- Branch: !`git branch --show-current`
- Working tree: !`git status --short`
- Recent history: !`git log --oneline --all --decorate -8`
- The current page, which step 5 replaces: @docs/STATUS.md

## Steps

### 1. Account for the session

Say, in a few lines: which area and branch this session worked on, which spec sections it
touched, whether a review brief was written or changed, and whether `swift test` is green.
If any code changed and the tests have not run since, run `swift test` now. If it is red,
stop here and report the failures; nothing below may describe red code as done.

### 2. Commit the code on its branch

Code and tests belong on the area's `area/<name>` branch. Commit anything uncommitted
there now, in small commits that name the spec section (`Spec 3 §5 — the live pointer`),
and push the branch if a remote exists. Leave the review brief and every other status
document uncommitted: they go to `main` in step 8. Never commit code on `main`.

### 3. Collect the spec interpretations

List every place this session chose a reading where the spec left room, or departed from
the spec's letter. For each: the spec section, what it left open, what was chosen, and the
alternative. If a review brief was written, take them from its "Choices made where the
spec left room" and "Deviations and spec corrections" so the two never disagree. If there
are none, say so.

### 4. Switch to `main`

`git checkout main`. Branches are plain branches in this folder, so this works once the
tree is clean apart from status documents; untracked files (a new brief) come along, and
nothing committed on the branch does. If the checkout is refused because `main` is checked
out in another worktree, stop and say so: status documents are never committed on a branch.
Stay on `main` afterwards; the next session reads STATUS.md there and checks out the area
branch itself.

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
- **Needs Adam**: three lists. *Briefs waiting for approval*, each with the decisions it
  asks for and the recommended answer. *Spec interpretations made so far*, a table
  `Spec | Left open | Chosen | Alternative`, with this session's items added. *Spec
  corrections proposed*, one line each: what the spec says, what the code does, the fix.
  An item leaves these lists only when Adam has answered it; the review brief keeps the
  record.
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

Stage only status documents, by path: `docs/STATUS.md`, `CHANGELOG.md`,
`docs/build-order.md`, `docs/reviews/`, and `CLAUDE.md` if the session changed it. Never
`git add -A` or `git add .`. Commit as `Status: Area N — <one line>`, or
`Status: docs — <one line>` for a session without an area, with the attribution line this
session uses. Do not push `main` unless Adam asked for it this session.

### 9. Print `docs/STATUS.md`

Print the whole of `docs/STATUS.md` as the last thing you say, after one line naming the
commit and the branch the code is on.
