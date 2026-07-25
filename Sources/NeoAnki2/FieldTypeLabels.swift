import NeoAnkiCore
import SwiftUI

private struct MediaStoreKey: EnvironmentKey {
    static let defaultValue: MediaStore? = nil
}

extension EnvironmentValues {
    var mediaStore: MediaStore? {
        get { self[MediaStoreKey.self] }
        set { self[MediaStoreKey.self] = newValue }
    }
}

enum FieldTypeLabels {
    static func name(for type: FieldType) -> String {
        switch type {
        case .text: "Text"
        case .richText: "Rich Text"
        case .audio: "Audio"
        case .image: "Image"
        case .gif: "GIF"
        case .video: "Video"
        case .number: "Number"
        case .cloze: "Cloze"
        }
    }

    static var authoringTypes: [FieldType] {
        [.text, .richText, .number, .audio, .image, .gif, .video, .cloze]
    }
}
