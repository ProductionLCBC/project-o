# ADR 0002: Everything is a command, addressed by number

Date: 2026-10-24 · Status: accepted

**Context.** Deep, user-controllable OSC is a priority, lighting consoles and Stream Decks will drive the presenter, and multi-campus references must survive renaming. **Decision.** Every operator action, cue, macro, key, OSC message and API call emits one command vocabulary (Spec 2) whose targets are numbers, never labels; every command has one canonical text form and one object form; the UI composes and shows commands but has no private verbs; "selected" is expanded to numbers before a command exists. **Consequences.** OSC, macros, logging, undo and testing fall out of one mechanism and console maps written at one campus work at every campus; the UI may never do anything the vocabulary cannot, so new UI features begin as vocabulary changes in the spec.

Amended 2026-11-08: the operator app's few local requests (Spec 10 §3), which control the engine process, the lock's secrets and the operator's own screen, sit outside the vocabulary.
