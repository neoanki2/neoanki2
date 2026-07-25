import SwiftUI

struct SchedulingCommands: Commands {
    let model: SchedulingModel?

    var body: some Commands {
        CommandMenu("Scheduling") {
            Button(model?.isOptimizing == true ? "Optimizing Scheduling…" : "Optimize Scheduling…") {
                guard let model else { return }
                Task { await model.optimize() }
            }
            .disabled(model == nil || model?.isOptimizing == true)
        }
    }
}
