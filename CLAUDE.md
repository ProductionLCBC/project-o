# CLAUDE.md — how to work in this repository

You are building a live-show presenter that churches will run on Sunday mornings.
A bug here is not a stack trace; it is a black screen in front of a thousand people.
Work accordingly: read the spec, write the tests, build to the tests, and never guess.

## Read first, every session

1. `docs/STATUS.md` — the one-page view: which area is live and on which branch, where
   the last session stopped, what Adam has not yet decided, and the next area's prompt.
2. `ARCHITECTURE.md` — the model in one page.
3. The one spec for the area you are working on, in `docs/specs/`. Not all of them.
4. The relevant section of `docs/ux-spec.md` only if the spec points you there.

The specs are the authority. If the code and a spec disagree, either the spec is
corrected first (say so, and stop) or the code is wrong. Never silently reinterpret.

## Current area

See `docs/STATUS.md`. Its **Now** line names the live area, its branch and where the last
session stopped; its **Next** block holds the next area's prompt, verbatim from
`docs/build-order.md`. `/wrap-up` moves both at the end of every session. Nothing about
the current area is written here, so this file never disagrees with STATUS.md.

## The loop (one area, one branch, one goal)

1. **Plan before code.** State what the spec requires, what you will build, and which
   tests prove it. Wait for approval of the plan on anything under `engine/`.
2. **Tests first.** Turn the spec's "tests this spec implies" and test tables into
   failing tests before implementation.
3. **Build in small commits**, each one leaving `main`-mergeable code.
4. **Run the tests.** `swift test` must be green before you report done.
5. **Write the review brief** at `docs/reviews/area-N-<name>.md` from
   `docs/reviews/TEMPLATE.md`: what the spec asked for, what was built, every place
   the spec left a choice and which option was taken and why, anything ambiguous or
   wrong in the spec, how the tests prove it, and what Adam needs to decide. Written
   for someone who knows the spec well and Swift barely; name files and spec sections,
   not line numbers. Leave the brief uncommitted and run `/wrap-up`: it commits the code
   on the branch and pushes it, then puts the brief, the `CHANGELOG.md` line, the area's
   `in review` status and `docs/STATUS.md` on `main`. Then stop.
6. **Wait for approval.** Adam reads the brief, not the Swift. He may ask questions;
   answer them from the code and the spec. Only when he writes `approved` do you merge
   the area branch into `main` with `--no-ff`, push, delete the branch, flip the area's
   status in `docs/build-order.md` to `shipped`, rewrite `docs/STATUS.md` so its Now and
   Next point at the next area (`/wrap-up` again), and start it in the same session if he
   asks.

Branches are plain branches in this folder (`area/<name>`); no worktrees, no pull
requests while the repository has one developer.

## Session contract

Every session, whatever it works on, docs sessions included:

- **Starts** by reading `docs/STATUS.md`, before the spec and before any code.
- **Ends** by running `/wrap-up` (`.claude/commands/wrap-up.md`), which rewrites
  `docs/STATUS.md` from the current truth, appends the session's line to `CHANGELOG.md`,
  files every new spec interpretation under Needs Adam (what the spec left open, what was
  chosen, the alternative), and commits.

`docs/STATUS.md` lives on `main` and is current on `main` after every session, even while
an area's code waits on its branch. So the end-of-session commit goes to `main` and carries
only status documents: `docs/STATUS.md`, `CHANGELOG.md`, `docs/build-order.md`,
`docs/reviews/` and this file. Code and tests stay on `area/<name>` until Adam writes
`approved`. A session that ends without that commit on `main` is not finished.

## Hard rules

These are enforced by tests or lints where possible, and by review otherwise.
Do not work around them; if one blocks you, stop and say so.

- `core/` (OCore) imports no Apple framework. Foundation is allowed only for `UUID`,
  `Codable`, and date parsing at the file boundary. Value types only; no classes.
- Nothing allocates, locks, logs to disk, touches a file or socket, or waits on a
  decoder or drawable on the render thread. Preallocate; hand over with lock-free rings.
- Every output presents a frame every refresh. A missing frame is a repeat, never black.
- Failures are detected on the render thread and recovered on another thread.
- No `fatalError`, no force-unwrap, no `try!` on anything that came from a file, a
  command, the network or a device. Unknown input is a `noop` effect and a log line.
- No clock reads in the projection; the frame is an argument. Engine time is monotonic.
- No new dependency in `engine/` or `core/` without an ADR in `docs/decisions/`.
- No copyrighted lyrics, media or fonts in the repo. Fixtures are public-domain hymns
  and synthetic media. OFL fonts only.
- Secrets (API tokens, Planning Center credentials) live in the Keychain, never in
  files, fixtures or commits.
- Merge to `main` only after Adam has written `approved` in reply to the area's review
  brief. Never on your own judgement, never because the tests are green.

## What you may do unattended

UI and tooling code against a spec; parsers and importers; writing tests and
documentation; dependency bumps with green tests; release notes.

## What you may never do unattended

Anything under `engine/` or `core/`; anything touching the render thread, decoders,
outputs, audio, or the show format; changes to `ARCHITECTURE.md`, a spec, or these
rules; adding a dependency; merging (which happens only on Adam's `approved`).

## Code conventions

- Swift 6 language mode, strict concurrency. `Sendable` on everything that crosses a
  thread. No `DispatchQueue` on the render path.
- Doc comments on every public type and function quote the spec section they
  implement: `/// Spec 3 §4 — Write semantics: media.`
- One `.metal` file per pass; variants via function constants; shaders are never
  string-assembled at runtime.
- Objective-C++ only inside the DeckLink module.
- JSON on disk: sorted keys, two-space indent, LF, camelCase, ms for time,
  `{num, den}` for frame rates. Unknown keys survive a round trip.
- Commands are stored as objects, printed and parsed in canonical text; `parse(print(x)) == x`.

## Commands

```
scripts/bootstrap.sh              # first run on a Mac: checks the toolchain, then builds and tests
swift build                       # everything
swift test                        # all tests
swift test --filter OCoreTests    # the projection and format tests (fast, no hardware)
scripts/soak.sh <scenario>        # test-bench soak; needs the bench Mac and outputs
scripts/golden.sh --update        # regenerate golden images after an intended render change
```

The hosted CI runs `swift build` and `swift test` on macOS and, for `core/` alone, on
Linux (`swift:6.1`); the Linux job is the proof that no Apple framework has crept into
OCore. The self-hosted bench Mac runs golden-image tests and the soak scenario; a
failure there blocks merging.

## Definition of done for an area

Spec page updated if needed → tests written from it → implementation → all tests
green in CI → soak green if the area touches the frame path → review brief in
`docs/reviews/` → one `CHANGELOG.md` line and `docs/STATUS.md` current on `main`
(`/wrap-up`) → Adam's `approved` → merged to `main` → the area's status flipped in
`docs/build-order.md` and `docs/STATUS.md` rewritten so Now and Next point at the
next area.

## Explaining your work

Adam is a production and AV engineer who knows the specs deeply and is new to Swift.
When you report, lead with decisions and consequences, not files and line counts.
Explain a Swift idiom the first time it matters to a decision (value semantics,
`Codable` synthesis, enums with associated values, `Sendable`), then stop explaining it.
If he asks "why did you do X", answer with the spec section, the alternatives you saw,
and the trade-off, in that order. Never attach time estimates.

## When unsure

Ask. Prefer a question in the plan step over an assumption in the code. If the spec
is silent, propose the smallest behaviour that keeps the five guarantees in
`docs/specs/4-render-pipeline.md` §1, and flag it for the spec.
