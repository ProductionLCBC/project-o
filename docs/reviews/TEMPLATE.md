# Area N — <name>: review brief

Branch: `area/<name>` · Spec: `docs/specs/<file>` · Tests: <count> passing on `swift test` · CI: <link or "not yet run">

Written for Adam: he knows the spec, not the Swift. Name spec sections and files, not line numbers. Lead with decisions. Keep it to one screen per section; the code is the long version.

## What the spec asked for

Three to six sentences: the area's purpose and the parts of the spec it covers.

## What was built

The shape of the result in plain words: the types, the functions, how they fit, and what a caller does with them. Mention the files so the pieces can be found.

## Choices made where the spec left room

The important section. One entry per place the spec allowed more than one reading or said nothing. For each:

- **Where:** spec section and the question it left open.
- **Options:** the readings considered.
- **Chosen:** which one, and why (spec intent, a later spec that depends on it, simplicity, testability).
- **Reversible?** What it would cost to change later.

## Deviations and spec corrections

Anything the code does differently from the spec's letter, or anything in the spec found to be inconsistent, with the proposed spec wording. Should be empty or short; if it is long, the spec needs a pass before approval.

## How the tests prove it

Which tests map to which spec sections; what the property, round-trip and replay tests cover; what is deliberately not covered yet and why.

## Swift notes for this area

Each idiom the first time it mattered, in one or two sentences, with the file it appears in.

## For Adam to decide

Questions that block approval, each with a recommended answer. If there are none, say so.
