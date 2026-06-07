import AppKit

@MainActor
final class SoundEffects {
    enum Event: CaseIterable, Hashable {
        case capture
        case resultReady
        case copy
        case insert
        case hardError

        var soundName: String {
            switch self {
            case .capture:
                return "Ping"
            case .copy:
                return "Tink"
            case .resultReady:
                return "Glass"
            case .insert:
                return "Pop"
            case .hardError:
                return "Funk"
            }
        }

        var volume: Float {
            switch self {
            case .capture:
                return 0.42
            case .copy:
                return 0.32
            case .resultReady, .insert:
                return 0.48
            case .hardError:
                return 0.62
            }
        }
    }

    private let runtimeStore: RuntimeConfigStore
    private var sounds: [Event: NSSound] = [:]

    init(runtimeStore: RuntimeConfigStore) {
        self.runtimeStore = runtimeStore
        for event in Event.allCases {
            if let sound = NSSound(named: NSSound.Name(event.soundName)) {
                sounds[event] = sound
            }
        }
    }

    func play(_ event: Event) {
        guard runtimeStore.soundsEnabled else { return }
        let sound: NSSound
        if let cached = sounds[event] {
            sound = cached
        } else if let loaded = NSSound(named: NSSound.Name(event.soundName)) {
            sounds[event] = loaded
            sound = loaded
        } else {
            return
        }
        if sound.isPlaying {
            sound.stop()
            sound.currentTime = 0
        }
        sound.volume = event.volume
        sound.play()
    }

    /// Warm the audio output route at launch so the first real `play(.capture)`
    /// on the hot path doesn't pay Core Audio's first-playback spin-up — which
    /// otherwise lands as a late chime on the first capture after launch. Plays
    /// the capture sound once at volume 0 (inaudible), independent of the
    /// sounds-enabled setting. Runs off the hot path, seconds before any real
    /// capture, so it can't race a real playback (the next `play` restores the
    /// event volume before sounding).
    func prewarm() {
        let sound: NSSound
        if let cached = sounds[.capture] {
            sound = cached
        } else if let loaded = NSSound(named: NSSound.Name(Event.capture.soundName)) {
            sounds[.capture] = loaded
            sound = loaded
        } else {
            return
        }
        sound.volume = 0
        sound.play()
    }
}
