# Area N — <name>: brief

The final message of the area's session, after `/wrap-up`. Four headings, nothing before the first and nothing after the last. Written for Adam: he knows the spec, not the Swift. Name spec sections and files, not line numbers. Lead with decisions; the code is the long version. Open the first section with one line: branch, spec, and whether `swift test` is green.

## What changed

Plain language: what the area now does, the shape of the result (the types, the functions, how they fit, what a caller does with them), and the files where the pieces can be found. Three to eight sentences.

## Spec interpretations

One entry per place the spec left room, or the code departs from its letter, in this shape:

- **Spec section — the question it left open.** Chose: what was done, and why. Alternative: the other reading, and what switching would cost. Spec correction proposed, if any.

These are the same items `/wrap-up` filed under Needs Adam in `docs/STATUS.md`; the two must agree.

## Tests

Which tests prove which spec sections; what the property, round-trip and replay tests cover; what is deliberately not covered yet and why.

## What's next

What Adam must decide before writing `approved`, each with a recommended answer; then the next area and what it waits for.
