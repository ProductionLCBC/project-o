# Architecture decision records

One paragraph each: context, decision, consequences. Numbered, never edited after acceptance; a reversal is a new ADR that supersedes the old one. Only decisions that change the architecture belong here; everything else lives in the specs.

| # | Decision |
| --- | --- |
| 0001 | Swift, a Metal-native engine, DeckLink SDI as the output tier |
| 0002 | Everything is a command, addressed by number |
| 0003 | Render once per channel, composite per output; nothing edits live |
| 0004 | 10-bit, premultiplied, linear-light compositing from the start |
| 0005 | OCore imports nothing from Apple frameworks |
| 0006 | Specs and tests are the durable assets; code is regenerated against them |
| 0007 | No Apple Developer Program membership before something workable exists |

Template: `0000-template.md`.
