import Foundation
import NeoAnkiApplication
import NeoAnkiCore
import NeoAnkiFeatures
import SwiftUI

public enum LearningTimeFormat {
    public static func duration(_ milliseconds: Int64) -> String {
        let seconds = max(0, milliseconds) / 1000
        if seconds < 60 { return "\(seconds)s" }
        if seconds < 3600 { return "\(seconds / 60)m \(seconds % 60)s" }
        return "\(seconds / 3600)h \((seconds % 3600) / 60)m"
    }
    public static func accessibleDuration(_ milliseconds: Int64) -> String {
        let seconds = max(0, milliseconds) / 1000
        return "\(seconds / 3600) hours, \((seconds % 3600) / 60) minutes, \(seconds % 60) seconds"
    }
}
