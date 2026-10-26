# tools/

Python tooling that talks to the engine as an API client: importers, the Planning Center lyric-doc tooling (the seed of the later lyric-to-slides generator), and the OSC driver script for the engine spike.

Nothing here may reach into the engine or the file format directly; it goes through the Spec 2 API or writes Spec 1 documents through the same validator the app uses.
