# Changelog

One line per session, newest first: an area's line when it reaches review or ships, a docs or tooling line otherwise. A weekly note, when wanted, is three lines at the top: shipped, learned, next.

## Unreleased

- 2026-10-26 — Session workflow: `docs/STATUS.md` as the one-page view every session reads first and rewrites last, the session contract in `CLAUDE.md` (status documents live on `main`, code waits on its branch), `/wrap-up` in `.claude/commands/`, and the Area 1 review brief committed under `docs/reviews/` with Area 1 set to `in review`. Docs only, on `main`. Next: Adam's `approved` on the Area 1 brief, then its merge and Area 2.
- 2026-10-26 — Spec 3, channel state and projection: `ShowState` and its value types, the Spec 2 command objects in the Spec 1 object form, `project()` with the §9 table as 24 tests plus determinism, Codable round-trip and supplementary tests, all green on `swift test` (`area/projection`). Next: review, then Spec 1 (objects and format) fills in the rest of the library types.
- 2026-10-25 — Repository created. The UX spec and Specs 1–4 exported from the planning docs into `docs/`, `ARCHITECTURE.md` and `CLAUDE.md` written, `OCore` and `OEngine` package skeleton with the import-rule test, CI for macOS and Linux. Next: the projection function and its test table (Spec 3).
