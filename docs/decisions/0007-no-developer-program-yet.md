# ADR 0007: No Apple Developer Program membership before something workable exists

Date: 2026-10-25 · Status: accepted

**Context.** LCBC holds no Apple Developer Program membership. An easily distributable, notarized build has no point before there is something worth distributing, and the pilot runs on machines LCBC controls. **Decision.** Build and run with local ad-hoc signing until Project O has a workable build; revisit membership, notarization and MDM distribution (Mosyle) when the pilot is scheduled. **Consequences.** Test machines need Gatekeeper exceptions or builds made on the machine itself; nothing in the repository may depend on entitlements that require a paid team; the engine's process model (a separate `OEngine` process) must work unsigned.
