# Changelog

One line per shipped area, newest first. A weekly note, when wanted, is three lines at the top: shipped, learned, next.

## Unreleased

- 2026-10-26 — Spec 3, channel state and projection: `ShowState` and its value types, the Spec 2 command objects in the Spec 1 object form, `project()` with the §9 table as 24 tests plus determinism, Codable round-trip and supplementary tests, all green on `swift test` (`area/projection`). Next: review, then Spec 1 (objects and format) fills in the rest of the library types.
- 2026-10-25 — Repository created. The UX spec and Specs 1–4 exported from the planning docs into `docs/`, `ARCHITECTURE.md` and `CLAUDE.md` written, `OCore` and `OEngine` package skeleton with the import-rule test, CI for macOS and Linux. Next: the projection function and its test table (Spec 3).
