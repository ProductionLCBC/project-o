# formats/

The Spec 1 format at the file boundary, beside the pure format code in `core/Format/`.

- `OFormats/` — the `OFormats` package target: the one place that touches disk for the two
  roots. It reads a root's documents into a `RootSnapshot` for the pure loader in `OCore`,
  executes the pure writer's `WritePlan` with the temporary file, fsync and rename of Spec 1 §5
  (`LocalFiles`), lists the media root for the missing state of §7, and hashes media files
  for §4 through `OCore`'s own SHA-256. Foundation and POSIX only, so it builds on Linux with
  the rest.
- `schemas/` — one JSON Schema (draft 2020-12) per document kind of Spec 1 §5:
  `library`, `channels`, `text-styles`, `grades`, `transitions`, `audio-transitions`,
  `preset`, `macro`, `list`, `media-index`, `machine`, `stacks`, `outputs`, `audio-outputs`,
  `inputs`, `clocks`, `keys`, `media-local`, `playlist`, `state`. They document the shapes for
  other tools; `tests/OCoreTests/SchemaTests.swift` keeps them honest against the fixture
  library. Objects allow additional properties on purpose: unknown keys survive a round trip
  (§8).

The `.pro` importer, which re-authors a ProPresenter library into Spec 1 documents through the
same validator the app uses, comes later. The fixture library lives in
`tests/fixtures/library-v1/` (Spec 1 §10), not here.
