import SwiftUI
import AppKit

// ─────────────────────────────────────────────────────────────────────────────
// clock's design system is **Apple's Clock app**, not Clatch's.
//
// Every other clapp-template fork carries the Clatch design system (the volt
// #E1FF00 Phosphor accent, Plus Jakarta Sans, 20px bordered panels). clock
// deliberately does not: a clock should look like a clock, so this mirrors Apple —
// SF Pro throughout, systemOrange as the one accent, systemGreen switches, no
// bundled typeface.
//
// Values here were measured from the shipping /System/Applications/Clock.app
// (assetutil on Assets.car, ObjC symbol dumps of MobileTimerUI.framework). Two
// facts drive the whole file:
//
//   1. Clock.app ships exactly ONE color asset — "Accent Color" = systemOrange.
//      Everything else is a system semantic token. Apple hardcodes nothing here,
//      so neither do we: never write a hex, find the semantic color.
//   2. Orange is CHROME ONLY (selected tab, +, timer ring, Pause, second hand).
//      Green is the switch and Start/Resume. Red is deletion. Gray is Cancel.
//      Apple keeps these as separate tokens; conflating them is the giveaway.
// ─────────────────────────────────────────────────────────────────────────────

// MARK: - Color

enum Palette {
    /// The single accent. Chrome only — never a surface behind text.
    static let accent = Color(nsColor: .systemOrange)
    /// Switches, Start and Resume. Never orange.
    static let switchOn = Color(nsColor: .systemGreen)
    static let go = Color(nsColor: .systemGreen)
    /// Deletion only. Cancel is *not* destructive.
    static let destructive = Color(nsColor: .systemRed)

    // Text, in Apple's four levels of emphasis.
    static let fg = Color(nsColor: .labelColor)
    static let fgDim = Color(nsColor: .secondaryLabelColor)
    static let fgMute = Color(nsColor: .tertiaryLabelColor)
    static let fgFaint = Color(nsColor: .quaternaryLabelColor)

    // Surfaces. On macOS the grouped-list relationship INVERTS the iOS one: the
    // card is *darker* than the page in dark mode (#1E1E1E on #323232) and lighter
    // in light mode (#FFFFFF on #ECECEC). Both fall out of these two tokens.
    static let bg = Color(nsColor: .windowBackgroundColor)     // the page
    static let card = Color(nsColor: .textBackgroundColor)     // grouped rows
    static let line = Color(nsColor: .separatorColor)
    /// Neutral control fill — the Cancel disc and the picker's selection band.
    static let fill = Color(nsColor: .systemFill)
    /// A row under the pointer. macOS uses the unfocused-selection colour for this,
    /// softened — strong enough to track the pointer, quiet enough not to read as
    /// a selection.
    static let hover = Color(nsColor: .unemphasizedSelectedContentBackgroundColor).opacity(0.55)
    /// The countdown ring's unfilled remainder. separatorColor (~10%) is
    /// near-invisible in light mode, so this is deliberately one tier stronger.
    static let ringTrack = Color(nsColor: .tertiaryLabelColor)

    // The analog dial is appearance-INDEPENDENT: it flips on the displayed time of
    // day (day/night), not on light/dark. These are the only literals in the file.
    static let faceDay = Color.white
    static let faceNight = Color.black

    static let nsBg = NSColor.windowBackgroundColor
}

enum Radius {
    static let card: CGFloat = 10      // inset-grouped card, .continuous
    static let control: CGFloat = 8
    static let band: CGFloat = 10      // picker selection band
}

enum Space {
    static let s1: CGFloat = 4, s2: CGFloat = 8, s3: CGFloat = 12
    static let s4: CGFloat = 16, s5: CGFloat = 24, s6: CGFloat = 32
    static let controlH: CGFloat = 32
    /// Leading inset inside a grouped card — also the separator inset.
    static let rowInset: CGFloat = 16
    /// The card's inset from the window edge.
    static let cardInset: CGFloat = 20
}

// MARK: - Type (SF Pro — the system face, nothing bundled)

extension Font {
    /// SF Pro at an explicit size/weight. Apple's Clock is built entirely from the
    /// system face. Its signature is a literal selector in the binary —
    /// `thinG2MonospacedDigitFontWithSize:` — i.e. big numerals are LIGHT weight
    /// with TABULAR digits. That detail carries more of the "Apple Clock" read than
    /// the orange does, so every ticking numeral below pairs .light with
    /// .monospacedDigit().
    ///
    /// Never `Font.custom("SF Pro Display", …)` — not a real installed family, it
    /// silently falls back to Helvetica and defeats the optical-size axis. Never
    /// `design: .rounded` — that's the Fitness/Home signature, not Clock's.
    static func sf(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight)
    }
}

// MARK: - Atoms

/// A section header. Mac uses Title Case with no letter-spacing — evidenced by
/// paired strings in Apple's own table (`STOPWATCH_LAP_HEADER="LAP NO."` for iOS
/// vs `..._MAC="Lap No."`). So: "Recent", never "RECENT", and never `.tracking()`.
struct SectionHeader: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(text)
            .font(.sf(13))
            .foregroundStyle(Palette.fgDim)
    }
}

/// A hairline separator, inset from the card's leading edge to sit under the
/// row's text. Apple draws none after the final row.
struct Hairline: View {
    var inset: CGFloat = Space.rowInset
    var body: some View {
        Palette.line.frame(height: 1).padding(.leading, inset)
    }
}

/// Names the agent that owns an alarm/timer. This is clock's own idea — Apple has
/// no equivalent — so it stays quiet: tinted text, never a filled capsule.
struct AgentTag: View {
    let name: String
    var dimmed: Bool = false
    init(_ name: String, dimmed: Bool = false) { self.name = name; self.dimmed = dimmed }
    var body: some View {
        Text(name)
            .font(.sf(11, .medium))
            .foregroundStyle(dimmed ? Palette.fgMute : Palette.accent)
    }
}

// MARK: - Controls

/// The alarm switch, at the Mac's own ~38×22 metrics.
///
/// Drawn rather than using a stock `Toggle(.switch)` for one reason: a macOS
/// NSSwitch takes the **user's system accent** unless a tint propagates, and Apple's
/// alarm switch is emphatically green (`mtui_switchTintColor`, a token they keep
/// separate from the app's orange). Owning the fill removes any chance of it
/// coming up blue on someone's machine.
struct AppleSwitch: View {
    @Binding var isOn: Bool
    var body: some View {
        Capsule()
            .fill(isOn ? Palette.switchOn : Palette.fgFaint)
            .frame(width: 38, height: 22)
            .overlay(alignment: isOn ? .trailing : .leading) {
                Circle()
                    .fill(.white)
                    .shadow(color: .black.opacity(0.2), radius: 0.8, y: 0.5)
                    .frame(width: 18, height: 18)
                    .padding(2)
            }
            .contentShape(Capsule())
            .onTapGesture {
                withAnimation(.spring(response: 0.22, dampingFraction: 0.8)) { isOn.toggle() }
            }
            .accessibilityAddTraits(.isButton)
    }
}

/// The round button under the timer ring. Apple's measured pattern is **label at
/// full strength, disc at 20% of the same hue** (disabled Start sits at 10%).
/// Cancel deliberately breaks the hue match — its label is `labelColor` over a
/// neutral fill, because gray-on-gray would be illegible.
struct CircleButtonStyle: ButtonStyle {
    var tint: Color
    var label: Color?
    var diameter: CGFloat = 72
    @Environment(\.isEnabled) private var enabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.sf(15))
            .foregroundStyle(enabled ? (label ?? tint) : (label ?? tint).opacity(0.4))
            .frame(width: diameter, height: diameter)
            .background(tint.opacity(enabled ? (configuration.isPressed ? 0.28 : 0.20) : 0.10))
            .clipShape(Circle())
            .contentShape(Circle())
    }
}

/// A plain tinted text button — Apple's sheet actions and the toolbar "+" carry no
/// chrome at all.
struct PlainTintStyle: ButtonStyle {
    @Environment(\.isEnabled) private var enabled
    var tint: Color = Palette.accent
    var weight: Font.Weight = .regular
    var size: CGFloat = 13
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.sf(size, weight))
            .foregroundStyle(enabled ? tint.opacity(configuration.isPressed ? 0.5 : 1) : Palette.fgMute)
            .contentShape(Rectangle())
    }
}

/// A quiet field for the alarm label — the one place text entry belongs in a clock.
struct AppleFieldStyle: TextFieldStyle {
    // swiftlint:disable:next identifier_name
    func _body(configuration: TextField<Self._Label>) -> some View {
        configuration
            .textFieldStyle(.plain)
            .font(.sf(13))
            .foregroundStyle(Palette.fg)
            .frame(height: Space.controlH)
            .padding(.horizontal, Space.s3)
            .background(Palette.fill)
            .clipShape(RoundedRectangle(cornerRadius: Radius.control, style: .continuous))
    }
}

/// The inset-grouped card that holds a run of rows: radius 10 continuous, no
/// border stroke, separators internal and inset.
struct GroupedCard<Content: View>: View {
    @ViewBuilder var content: () -> Content
    var body: some View {
        VStack(spacing: 0) { content() }
            .background(Palette.card)
            .clipShape(RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
    }
}
