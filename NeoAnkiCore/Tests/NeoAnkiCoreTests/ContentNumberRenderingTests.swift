import Foundation
import Testing

@testable import NeoAnkiCore

@Test func itemDisplayFormatsFiniteNumbersForTheRequestedLocale() {
    #expect(
        ItemDisplay.plainText(
            from: .number(1_234.5),
            locale: Locale(identifier: "en_US")
        ) == "1,234.5"
    )
    #expect(
        ItemDisplay.plainText(
            from: .number(42),
            locale: Locale(identifier: "en_US")
        ) == "42"
    )
}

@Test func itemDisplayRejectsNonFiniteNumbers() {
    let locale = Locale(identifier: "en_US")
    #expect(ItemDisplay.plainText(from: .number(.nan), locale: locale) == "Invalid number")
    #expect(ItemDisplay.plainText(from: .number(.infinity), locale: locale) == "Invalid number")
}
