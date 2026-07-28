import SwiftUI

struct SchedulingCommands: Commands {
    let model: SchedulingModel?

    var body: some Commands {
        // Parameter fitting is not here on purpose: it happens on its own when
        // history warrants it. What remains is the one scheduling decision that
        // is the learner's to make.
        CommandMenu("Scheduling") {
            Button("Scheduling Settings…") {
                model?.openSettings()
            }
            .disabled(model == nil)
        }
    }
}
