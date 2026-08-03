import Foundation

struct ModifierChordSet: OptionSet, Equatable {
    let rawValue: UInt8

    static let control = ModifierChordSet(rawValue: 1 << 0)
    static let option = ModifierChordSet(rawValue: 1 << 1)
    static let command = ModifierChordSet(rawValue: 1 << 2)
    static let shift = ModifierChordSet(rawValue: 1 << 3)
    static let capsLock = ModifierChordSet(rawValue: 1 << 4)
    static let function = ModifierChordSet(rawValue: 1 << 5)
}

enum ModifierChordAction: Equatable {
    case createNote
    case toggleVisibility
}

/// Recognizes exact modifier-only chords without firing while a normal keyboard
/// shortcut is still in progress. An armed chord fires once, after all modifiers
/// are released, and is cancelled by any extra modifier or non-modifier key.
struct ModifierChordRecognizer {
    private struct ArmedChord {
        let modifiers: ModifierChordSet
        let action: ModifierChordAction
        var isCancelled: Bool
    }

    private var armedChord: ArmedChord?

    mutating func handleFlagsChanged(_ modifiers: ModifierChordSet) -> ModifierChordAction? {
        if var armedChord {
            if modifiers.isEmpty {
                self.armedChord = nil
                return armedChord.isCancelled ? nil : armedChord.action
            }

            if !modifiers.isSubset(of: armedChord.modifiers) {
                armedChord.isCancelled = true
                self.armedChord = armedChord
            }
            return nil
        }

        switch modifiers {
        case [.control, .option]:
            armedChord = ArmedChord(
                modifiers: modifiers,
                action: .createNote,
                isCancelled: false
            )
        case [.command, .option]:
            armedChord = ArmedChord(
                modifiers: modifiers,
                action: .toggleVisibility,
                isCancelled: false
            )
        default:
            break
        }
        return nil
    }

    mutating func handleNonModifierKeyDown() {
        cancelArmedChord()
    }

    mutating func handleExtraModifier() {
        cancelArmedChord()
    }

    private mutating func cancelArmedChord() {
        guard var armedChord else { return }
        armedChord.isCancelled = true
        self.armedChord = armedChord
    }

    mutating func reset() {
        armedChord = nil
    }
}
