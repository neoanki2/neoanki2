import NeoAnkiCore
import SwiftUI

struct GradeGuideView: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("How to grade")
                .font(.headline)

            Text("After you reveal or check your answer, pick the option that best matches how well you recalled it. NeoAnki2 uses your choice to schedule the next review.")
                .font(.body)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Divider()

            ForEach(ReviewRating.allCases, id: \.self) { rating in
                HStack(alignment: .top, spacing: 12) {
                    Text(rating.studyButtonTitle)
                        .font(.body.bold())
                        .frame(width: 52, alignment: .leading)
                    Text(rating.studyTooltip)
                        .font(.body)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Text("Keyboard: press 1–4 to grade when the buttons are visible.")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .padding(20)
        .frame(width: 360)
    }
}
