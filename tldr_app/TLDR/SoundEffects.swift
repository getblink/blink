import AppKit

@MainActor
final class SoundEffects {
    enum Event {
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

    init(runtimeStore: RuntimeConfigStore) {
        self.runtimeStore = runtimeStore
    }

    func play(_ event: Event) {
        guard runtimeStore.soundsEnabled,
              let sound = NSSound(named: NSSound.Name(event.soundName))
        else { return }
        sound.volume = event.volume
        sound.play()
    }
}
