# CLAUDE.md — how to work in this repository

You are building a live-show presenter that churches will run on Sunday mornings.
A bug here is not a stack trace; it is a black screen in front of a thousand people.
Work accordingly: read the spec, write the tests, build to the tests, and never guess.

## Read first, every session

1. `ARCHITECTURE.md` — the model in one page.
2. The one spec for the area you are working on, in `docs/specs/`. Not all of them.
3. The relevant section of `docs/ux-spec.md` only if the spec points you there.

The specs are the authority. If the code and a spec disagree, either the spec is
corrected first (say so, and stop) or the code is wrong. Never silently reinterpret.

## Current area

**Area 2 — object model and library format** (`docs/specs/1-objects-and-format.md`).
Target: `core/` (documents, loader, writer, validator, migrations) and `formats/` (JSON
schemas). Start with the fixture library in `tests/fixtures/library-v1/` from the worked
examples in §9, then the §10 tests, then the code. Reuse the types Area 1 left in
`core/Library/`, `core/Commands/` and `core/State/`; extend, do not duplicate. The full
prompt is in `docs/build-order.md`. When an area ships, point this section at the next one.

## The loop (one area, one branch, one goal)

1. **Plan before code.** State what the spec requires, what you will build, and which
   tests prove it. Wait for approval of the plan on anything under `engine/`.
2. **Tests first.** Turn the spec's "tests this spec implies" and test tables into
   failing tests before implementation.
3. **Build in small commits**, each one leaving `main`-mergeable code.
4. **Run the tests.** `swift test` must be green before you report done.
5. **Report**: what you built, what you did not, and anything in the spec that
   turned out ambiguous. Then add one line to `CHANGELOG.md`.

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
- Never merge to `main`. Open the change for review.

## What you may do unattended

UI and tooling code against a spec; parsers and importers; writing tests and
documentation; dependency bumps with green tests; release notes.

## What you may never do unattended

Anything under `engine/` or `core/`; anything touching the render thread, decoders,
outputs, audio, or the show format; changes to `ARCHITECTURE.md`, a spec, or these
rules; adding a dependency; merging.

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
green in CI → soak green if the area touches the frame path → one `CHANGELOG.md` line
→ the area's status flipped in `docs/build-order.md` and the Current area above
pointed at the next one.

## When unsure

Ask. Prefer a question in the plan step over an assumption in the code. If the spec
is silent, propose the smallest behaviour that keeps the five guarantees in
`docs/specs/4-render-pipeline.md` §1, and flag it for the spec.
