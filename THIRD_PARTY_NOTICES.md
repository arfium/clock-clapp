# Third-Party Notices

clock's structure and transport layer are derived from
[clapp-template](../clapp-template).

## Fonts

**None bundled.** clock uses the system typeface (SF Pro) throughout, so nothing is
redistributed. Earlier revisions bundled Plus Jakarta Sans as part of the Clatch
design system; that dependency was removed when the app was restyled after Apple's
Clock (see below).

## Visual design

clock's interface deliberately follows the design of Apple's **Clock** app — its
palette (systemOrange chrome, systemGreen switches), SF Pro type scale, grouped row
layout, analog dial proportions, and app-icon geometry. This is a homage in an
unaffiliated third-party utility: clock is not produced, endorsed, or approved by
Apple, ships no Apple code or artwork, and reproduces no Apple asset — every element
is drawn from scratch in this repository (`ClockFace.swift`,
`scripts/render-clock-icon.swift`). "Apple" and "Clock" are trademarks of Apple Inc.

Note that this makes clock the one clapp-template fork that does **not** carry the
Clatch design system; see the header of `native/Sources/clock/Theme.swift`.

Everything else builds against Apple's system frameworks only (Foundation, AppKit,
SwiftUI).
