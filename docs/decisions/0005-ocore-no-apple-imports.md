# ADR 0005: OCore imports nothing from Apple frameworks

Date: 2026-10-25 · Status: accepted

**Context.** The projection, the command grammar and the file format are the parts of the system that must be testable to death, replayable from a log, and one day portable; they are also the safest place to learn Swift. **Decision.** The `OCore` package target imports Foundation only (for `UUID`, `Codable` and date parsing at the file boundary), contains only value types, reads no clock and performs no I/O; a test scans its imports and fails the build on anything else, and CI builds and tests it on Linux. **Consequences.** OCore stays a pure function library that any backend can consume, Windows remains possible without a rewrite of the model, and every engine or UI concern that wants to leak into the core has to be argued for as a new ADR instead of slipped in.
