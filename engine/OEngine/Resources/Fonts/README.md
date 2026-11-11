# Fonts bundled with the engine

Spec 6 §4 (P14) and choices T-6 and T-7: the engine registers these fonts for its own
process at launch, so a preset that names them renders at every campus with nothing
installed. A font of the same PostScript name installed on the machine wins, and the clash
is logged once. ADR 0008 records the decision. OFL fonts only (`CLAUDE.md`).

| File | Family | Version | SHA-256 |
| --- | --- | --- | --- |
| `DMSans[opsz,wght].ttf` | DM Sans, roman, variable (opsz 9–40, wght 100–1000) | 4.004 | `8cd08d97e89c24d0aa92edd2f0f4c8ee6195eee9b7c9f154865a58b02f0c1c0d` |
| `DMSans-Italic[opsz,wght].ttf` | DM Sans, italic, variable (opsz 9–40, wght 100–1000) | 4.004 | `22259c0cc8237221b80f44c76ba8d36e6bce3cda72779f5b2773643d499720ae` |
| `OFL.txt` | SIL Open Font License 1.1, Copyright 2014 The DM Sans Project Authors | | `9af36190332437f5ecd09974de43c1f7c77a310a996cdd8ceb25628b458840e1` |

**Source.** The `ofl/dmsans` folder of github.com/google/fonts at commit
`5b35b7208dd4100571326fdf37f030b32a524232` (2026-05-21), unmodified; each file's git blob
hash matched that commit's listing when it was copied here (2026-11-10). The licence names
no Reserved Font Name.

**Names.** Core Text names the roman file's default instance `DMSans-9ptRegular` and its
named instances `DMSans-9ptRegular_Thin` through `DMSans-9ptRegular_Black`; the italic's
are `DMSans-9ptItalic` and `DMSans-9ptItalic_Thin-Italic` and so on. The engine also answers
to the usual names of the static fonts, `DMSans-Thin` through `DMSans-Black` and
`DMSans-ThinItalic` through `DMSans-BlackItalic` (family and style without spaces), each
mapped to the matching named instance (Adam's answer of 2026-11-10).

DM Sans has no tabular figures, so a clock set in it still shifts as it counts (Spec 6 §4,
T-10: tabular digits "when the font has them").
