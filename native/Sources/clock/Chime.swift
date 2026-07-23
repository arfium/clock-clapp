import AppKit

// The chime — one soft ascending marimba arrival (G5→C6→E6), bundled as a WAV and
// played when an alarm or timer fires. The signal wakes the agent; the chime is the
// human's cue. (Regenerate the tone with: swift scripts/render-chime.swift)
enum Chime {
    private static var sound: NSSound?   // retained so it isn't deallocated mid-play

    static func play() {
        guard let url = Bundle.module.url(forResource: "chime", withExtension: "wav"),
              let s = NSSound(contentsOf: url, byReference: true) else { return }
        sound = s
        s.play()
    }
}
