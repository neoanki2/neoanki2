import XCTest

/// The functional UI suite has seven process-level journeys. Each legacy check
/// remains a named activity so failures preserve their original identity while
/// compatible checks share the same app process.
final class FastFunctionalJourneyTests: NeoAnkiUITestCase {
    func testVocabularyJourney() throws {
        try runSharedVocabularyJourney()
    }

    func testLibraryAndBrowseJourney() throws {
        if !hasActivityFilters {
            try runSharedLibraryAndBrowseJourney()
            return
        }

        try runLegacyCheck("ScopeHomeAndBrowseUITests.testScopeHomeLeadsWithDueCountAndStudy") { try checkScopeHomeAndBrowseUITestsScopeHomeLeadsWithDueCountAndStudy() }
        try runLegacyCheck("ScopeHomeAndBrowseUITests.testScopeHomeDoesNotRevealAnswers") { try checkScopeHomeAndBrowseUITestsScopeHomeDoesNotRevealAnswers() }
        try runLegacyCheck("ScopeHomeAndBrowseUITests.testBrowseOpensWithKeyboardShortcutAndClosesWithEscape") { try checkScopeHomeAndBrowseUITestsBrowseOpensWithKeyboardShortcutAndClosesWithEscape() }
        try runLegacyCheck("ScopeHomeAndBrowseUITests.testBrowseOpensFromTheLibraryMenu") { try checkScopeHomeAndBrowseUITestsBrowseOpensFromTheLibraryMenu() }
        try runLegacyCheck("ScopeHomeAndBrowseUITests.testBrowseSearchNarrowsRowsAndReportsNoResults") { try checkScopeHomeAndBrowseUITestsBrowseSearchNarrowsRowsAndReportsNoResults() }
        try runLegacyCheck("ScopeHomeAndBrowseUITests.testBrowseHidesTheAnswerColumnByDefault") { try checkScopeHomeAndBrowseUITestsBrowseHidesTheAnswerColumnByDefault() }
        try runLegacyCheck("ScopeHomeAndBrowseUITests.testAddItemHasAMenuHomeUnderFile") { try checkScopeHomeAndBrowseUITestsAddItemHasAMenuHomeUnderFile() }
        try runLegacyCheck("ScopeHomeAndBrowseUITests.testBrowseRevealsTheAnswerColumnFromTheLibraryMenu") { try checkScopeHomeAndBrowseUITestsBrowseRevealsTheAnswerColumnFromTheLibraryMenu() }
        try runLegacyCheck("ScopeHomeAndBrowseUITests.testAnswerColumnChoiceSurvivesLeavingBrowseMode") { try checkScopeHomeAndBrowseUITestsAnswerColumnChoiceSurvivesLeavingBrowseMode() }
        try runLegacyCheck("ScopeHomeAndBrowseUITests.testBrowseDeletesASelectedItem") { try checkScopeHomeAndBrowseUITestsBrowseDeletesASelectedItem() }
        try runLegacyCheck("ScopeHomeAndBrowseUITests.testBrowseMovesASelectedItemToADeck") { try checkScopeHomeAndBrowseUITestsBrowseMovesASelectedItemToADeck() }
        try runLegacyCheck("LibraryUITests.testAppLaunchesWithEmptyLibrary") { try checkLibraryUITestsAppLaunchesWithEmptyLibrary() }
        try runLegacyCheck("LibraryUITests.testAddItemFromEmptyState") { try checkLibraryUITestsAddItemFromEmptyState() }
        try runLegacyCheck("LibraryUITests.testAddItemFromToolbar") { try checkLibraryUITestsAddItemFromToolbar() }
        try runLegacyCheck("LibraryUITests.testRichTextEditorFormattingButtonsApplyStyles") { try checkLibraryUITestsRichTextEditorFormattingButtonsApplyStyles() }
        try runLegacyCheck("LibraryUITests.testAddItemCancelReturnsToLibrary") { try checkLibraryUITestsAddItemCancelReturnsToLibrary() }
        try runLegacyCheck("LibraryUITests.testAddItemValidationDisablesSave") { try checkLibraryUITestsAddItemValidationDisablesSave() }
        try runLegacyCheck("LibraryUITests.testOpenItemDetail") { try checkLibraryUITestsOpenItemDetail() }
        try runLegacyCheck("LibraryUITests.testBackFromItemDetailReturnsToLibrary") { try checkLibraryUITestsBackFromItemDetailReturnsToLibrary() }
        try runLegacyCheck("LibraryUITests.testDeleteAllUnassignedFromToolbar") { try checkLibraryUITestsDeleteAllUnassignedFromToolbar() }
        try runLegacyCheck("LibraryUITests.testDeleteAllUnassignedFromSidebarMenu") { try checkLibraryUITestsDeleteAllUnassignedFromSidebarMenu() }
        try runLegacyCheck("LibraryUITests.testEditItemFromDetailUpdatesLibraryAndPreview") { try checkLibraryUITestsEditItemFromDetailUpdatesLibraryAndPreview() }
        try runLegacyCheck("LibraryUITests.testDirtyItemEditCanKeepEditingThenDiscard") { try checkLibraryUITestsDirtyItemEditCanKeepEditingThenDiscard() }
        try runLegacyCheck("LibraryUITests.testDeleteItemFromDetail") { try checkLibraryUITestsDeleteItemFromDetail() }
        try runLegacyCheck("LibraryUITests.testMoveItemToDeckFromDetail") { try checkLibraryUITestsMoveItemToDeckFromDetail() }
        try runLegacyCheck("LibraryUITests.testDeleteItemCancellationPreservesItem") { try checkLibraryUITestsDeleteItemCancellationPreservesItem() }
        try runLegacyCheck("LibraryUITests.testWhitespaceOnlyRequiredFieldsCannotBeSaved") { try checkLibraryUITestsWhitespaceOnlyRequiredFieldsCannotBeSaved() }
    }

    func testDecksAndAuthoringJourney() throws {
        if !hasActivityFilters {
            try runSharedDecksAndAuthoringJourney()
            return
        }

        try runLegacyCheck("DeckUITests.testCreateDeckFromSidebar") { try checkDeckUITestsCreateDeckFromSidebar() }
        try runLegacyCheck("DeckUITests.testRenameDeck") { try checkDeckUITestsRenameDeck() }
        try runLegacyCheck("DeckUITests.testDeleteDeckWithConfirmation") { try checkDeckUITestsDeleteDeckWithConfirmation() }
        try runLegacyCheck("DeckUITests.testSwitchScopesFiltersItems") { try checkDeckUITestsSwitchScopesFiltersItems() }
        try runLegacyCheck("LibraryUITests.testAddItemWithDeckPicker") { try checkLibraryUITestsAddItemWithDeckPicker() }
        try runLegacyCheck("DeckUITests.testScopedStudyFromDeckSelection") { try checkDeckUITestsScopedStudyFromDeckSelection() }
        try runLegacyCheck("DeckUITests.testCancelCreatingDeckLeavesSidebarUnchanged") { try checkDeckUITestsCancelCreatingDeckLeavesSidebarUnchanged() }
        try runLegacyCheck("DeckUITests.testCancelRenameKeepsOriginalDeckName") { try checkDeckUITestsCancelRenameKeepsOriginalDeckName() }
        try runLegacyCheck("DeckUITests.testCancelDeleteKeepsDeck") { try checkDeckUITestsCancelDeleteKeepsDeck() }
        try runLegacyCheck("DeckUITests.testCreateSubdeckFromContextMenu") { try checkDeckUITestsCreateSubdeckFromContextMenu() }
        try runLegacyCheck("DeckUITests.testSelectingParentDoesNotExpandItsSubdecks") { try checkDeckUITestsSelectingParentDoesNotExpandItsSubdecks() }
        try runLegacyCheck("DeckUITests.testDeleteDeckRemovesSubdecksAndItems") { try checkDeckUITestsDeleteDeckRemovesSubdecksAndItems() }
        try runLegacyCheck("AuthoringUITests.testAddItemWithNumberField") { try checkAuthoringUITestsAddItemWithNumberField() }
        try runLegacyCheck("AuthoringUITests.testAddItemWithMultipleItemTypes") { try checkAuthoringUITestsAddItemWithMultipleItemTypes() }
        try runLegacyCheck("AuthoringUITests.testClozeAuthoringMarkBlank") { try checkAuthoringUITestsClozeAuthoringMarkBlank() }
        try runLegacyCheck("AuthoringUITests.testMediaFieldRequiresDescription") { try checkAuthoringUITestsMediaFieldRequiresDescription() }
        try runLegacyCheck("LibraryUITests.testImageEditRequiresDescriptionBeforeSaving") { try checkLibraryUITestsImageEditRequiresDescriptionBeforeSaving() }
        try runLegacyCheck("AuthoringUITests.testEmptyDeckAddItem") { try checkAuthoringUITestsEmptyDeckAddItem() }
        try runLegacyCheck("AuthoringUITests.testUnassignedScopeEmptyState") { try checkAuthoringUITestsUnassignedScopeEmptyState() }
        try runLegacyCheck("AuthoringUITests.testItemPreviewRendersRichText") { try checkAuthoringUITestsItemPreviewRendersRichText() }
        try runLegacyCheck("AuthoringUITests.testEditItemChangeItemType") { try checkAuthoringUITestsEditItemChangeItemType() }
    }

    func testTemplatesAndItemTypesJourney() throws {
        if !hasActivityFilters {
            try runSharedTemplatesAndItemTypesJourney()
            return
        }

        try runLegacyCheck("TemplatesUITests.testTemplatesOpensAndShowsBasicTemplate") { try checkTemplatesUITestsTemplatesOpensAndShowsBasicTemplate() }
        try runLegacyCheck("TemplatesUITests.testTemplatesLayoutDoesNotOverlapColumns") { try checkTemplatesUITestsTemplatesLayoutDoesNotOverlapColumns() }
        try runLegacyCheck("TemplatesUITests.testTemplatesAddReverseTemplate") { try checkTemplatesUITestsTemplatesAddReverseTemplate() }
        try runLegacyCheck("TemplatesUITests.testNewTemplateKeepsAdvancedSettingsCollapsedByDefault") { try checkTemplatesUITestsNewTemplateKeepsAdvancedSettingsCollapsedByDefault() }
        try runLegacyCheck("TemplatesUITests.testTemplatesCreateItemType") { try checkTemplatesUITestsTemplatesCreateItemType() }
        try runLegacyCheck("TemplatesUITests.testTemplatesEditItemType") { try checkTemplatesUITestsTemplatesEditItemType() }
        try runLegacyCheck("TemplatesUITests.testTemplatesDeleteBasicStarter") { try checkTemplatesUITestsTemplatesDeleteBasicStarter() }
        try runLegacyCheck("TemplatesUITests.testTemplatesDeleteCustomItemType") { try checkTemplatesUITestsTemplatesDeleteCustomItemType() }
        try runLegacyCheck("TemplatesUITests.testTemplatesEditTemplateName") { try checkTemplatesUITestsTemplatesEditTemplateName() }
        try runLegacyCheck("TemplatesUITests.testTemplatesDeleteTemplate") { try checkTemplatesUITestsTemplatesDeleteTemplate() }
        try runLegacyCheck("TemplatesUITests.testTemplatesCancelTemplateEditor") { try checkTemplatesUITestsTemplatesCancelTemplateEditor() }
        try runLegacyCheck("TemplatesUITests.testItemTypeValidationDisablesSaveForBlankName") { try checkTemplatesUITestsItemTypeValidationDisablesSaveForBlankName() }
        try runLegacyCheck("TemplatesUITests.testDirtyItemTypeCanKeepEditingThenDiscard") { try checkTemplatesUITestsDirtyItemTypeCanKeepEditingThenDiscard() }
        try runLegacyCheck("TemplatesUITests.testItemTypeFieldsCanBeAddedReorderedAndRemoved") { try checkTemplatesUITestsItemTypeFieldsCanBeAddedReorderedAndRemoved() }
        try runLegacyCheck("TemplatesUITests.testTemplateValidationAndDiscardConfirmation") { try checkTemplatesUITestsTemplateValidationAndDiscardConfirmation() }
        try runLegacyCheck("TemplatesUITests.testDeleteTemplateCanBeCancelled") { try checkTemplatesUITestsDeleteTemplateCanBeCancelled() }
        try runLegacyCheck("TemplatesAdvancedUITests.testTemplateInteractionPickerAllTypes") { try checkTemplatesAdvancedUITestsTemplateInteractionPickerAllTypes() }
        try runLegacyCheck("TemplatesAdvancedUITests.testTemplateAdvancedSettingsExpand") { try checkTemplatesAdvancedUITestsTemplateAdvancedSettingsExpand() }
        try runLegacyCheck("TemplatesAdvancedUITests.testRepairCorruptedItemType") { try checkTemplatesAdvancedUITestsRepairCorruptedItemType() }
        try runLegacyCheck("TemplatesAdvancedUITests.testFieldTypePicker") { try checkTemplatesAdvancedUITestsFieldTypePicker() }
        try runLegacyCheck("TemplatesAdvancedUITests.testDeleteTemplateCancel") { try checkTemplatesAdvancedUITestsDeleteTemplateCancel() }
        try runLegacyCheck("TemplatesAdvancedUITests.testCannotDeleteItemTypeWithItems") { try checkTemplatesAdvancedUITestsCannotDeleteItemTypeWithItems() }
        try runLegacyCheck("TemplatesAdvancedUITests.testTemplatesKeyboardShortcut") { try checkTemplatesAdvancedUITestsTemplatesKeyboardShortcut() }
    }

    /// Independent processes keep the longest Studio coverage below one CI
    /// shard while preserving the same protected repository scenarios.
    func testTemplatesAndItemTypesRepairAndImpact() throws {
        guard !hasActivityFilters else { return }
        try runStudioRepairAndImpactJourneys()
    }

    func testTemplatesAndItemTypesSafeguards() throws {
        guard !hasActivityFilters else { return }
        try runProtectedItemTypeSafeguardJourneys()
    }

    func testStudyAndSchedulingJourney() throws {
        if !hasActivityFilters {
            try runSharedStudyAndSchedulingJourney()
            return
        }

        try runLegacyCheck("StudyUITests.testStudyBasicItemFlow") { try checkStudyUITestsStudyBasicItemFlow() }
        try runLegacyCheck("StudyUITests.testStudyAllGradeButtons") { try checkStudyUITestsStudyAllGradeButtons() }
        try runLegacyCheck("StudyUITests.testStudyAgainGrade") { try checkStudyUITestsStudyAgainGrade() }
        try runLegacyCheck("StudyUITests.testStudyHardGrade") { try checkStudyUITestsStudyHardGrade() }
        try runLegacyCheck("StudyUITests.testStudyEasyGrade") { try checkStudyUITestsStudyEasyGrade() }
        try runLegacyCheck("StudyUITests.testStudyMultiCardSession") { try checkStudyUITestsStudyMultiCardSession() }
        try runLegacyCheck("StudyUITests.testStudyEndSessionWithConfirmation") { try checkStudyUITestsStudyEndSessionWithConfirmation() }
        try runLegacyCheck("StudyUITests.testStudyGradeHelpPopover") { try checkStudyUITestsStudyGradeHelpPopover() }
        try runLegacyCheck("StudyUITests.testStudyReverseTemplate") { try checkStudyUITestsStudyReverseTemplate() }
        try runLegacyCheck("StudyUITests.testTypedAnswerRequiresInputThenAcceptsCorrectAnswer") { try checkStudyUITestsTypedAnswerRequiresInputThenAcceptsCorrectAnswer() }
        try runLegacyCheck("StudyUITests.testTypedAnswerReportsIncorrectResponse") { try checkStudyUITestsTypedAnswerReportsIncorrectResponse() }
        try runLegacyCheck("StudyUITests.testChoiceRequiresSelectionThenChecksCorrectChoice") { try checkStudyUITestsChoiceRequiresSelectionThenChecksCorrectChoice() }
        try runLegacyCheck("StudyUITests.testArrangeUncheckedOrderIsReportedIncorrect") { try checkStudyUITestsArrangeUncheckedOrderIsReportedIncorrect() }
        try runLegacyCheck("StudyUITests.testClozeConcealsThenRevealsBlank") { try checkStudyUITestsClozeConcealsThenRevealsBlank() }
        try runLegacyCheck("StudyUITests.testRecordRequiresRecordingButAllowsSelfGradeFallback") { try checkStudyUITestsRecordRequiresRecordingButAllowsSelfGradeFallback() }
        try runLegacyCheck("StudyUITests.testUndoLastGradeRestoresReviewedCard") { try checkStudyUITestsUndoLastGradeRestoresReviewedCard() }
        try runLegacyCheck("StudyExtendedUITests.testStartStudyViaMenu") { try checkStudyExtendedUITestsStartStudyViaMenu() }
        try runLegacyCheck("StudyExtendedUITests.testEndStudyViaMenuWithConfirmation") { try checkStudyExtendedUITestsEndStudyViaMenuWithConfirmation() }
        try runLegacyCheck("StudyExtendedUITests.testGradeViaKeyboardShortcuts") { try checkStudyExtendedUITestsGradeViaKeyboardShortcuts() }
        try runLegacyCheck("StudyExtendedUITests.testContinueViaSpace") { try checkStudyExtendedUITestsContinueViaSpace() }
        try runLegacyCheck("StudyExtendedUITests.testUndoLastGradeViaCommandZ") { try checkStudyExtendedUITestsUndoLastGradeViaCommandZ() }
        try runLegacyCheck("StudyExtendedUITests.testArrangeReorderToCorrectOrder") { try checkStudyExtendedUITestsArrangeReorderToCorrectOrder() }
        try runLegacyCheck("StudyExtendedUITests.testArrangeKeyboardReorder") { try checkStudyExtendedUITestsArrangeKeyboardReorder() }
        try runLegacyCheck("StudyExtendedUITests.testRevealAndSelfGradeViaRightArrow") { try checkStudyExtendedUITestsRevealAndSelfGradeViaRightArrow() }
        try runLegacyCheck("StudyExtendedUITests.testStudyCaughtUpState") { try checkStudyExtendedUITestsStudyCaughtUpState() }
        try runLegacyCheck("ScopeHomeAndBrowseUITests.testScopeHomeReportsNextDueInsteadOfADeadStudyButton") { try checkScopeHomeAndBrowseUITestsScopeHomeReportsNextDueInsteadOfADeadStudyButton() }
        try runLegacyCheck("LibraryUITests.testSchedulingMenuOffersOnlySettings") { try checkLibraryUITestsSchedulingMenuOffersOnlySettings() }
        try runLegacyCheck("LibraryUITests.testEndingASessionOptimizesWithoutInterrupting") { try checkLibraryUITestsEndingASessionOptimizesWithoutInterrupting() }
        try runLegacyCheck("StudyExtendedUITests.testEditCardDuringSessionKeepsStudying") { try checkStudyExtendedUITestsEditCardDuringSessionKeepsStudying() }
        try runLegacyCheck("StudyExtendedUITests.testEditCardViaCommandEThenCancel") { try checkStudyExtendedUITestsEditCardViaCommandEThenCancel() }
        try runLegacyCheck("StudyExtendedUITests.testDismissUndoBanner") { try checkStudyExtendedUITestsDismissUndoBanner() }
    }

    func testImportAndPortableTransferJourney() throws {
        if !hasActivityFilters {
            try runSharedImportAndPortableTransferJourney()
            return
        }

        try runLegacyCheck("ImportExportUITests.testImportWithMediaDirectory") { try checkImportExportUITestsImportWithMediaDirectory() }
        try runLegacyCheck("ImportExportUITests.testImportFilePickerCancel") { try checkImportExportUITestsImportFilePickerCancel() }
        try runLegacyCheck("ImportExportUITests.testImportProgressIndicator") { try checkImportExportUITestsImportProgressIndicator() }
        try runLegacyCheck("ImportExportUITests.testCSVImportItemTypePicker") { try checkImportExportUITestsCSVImportItemTypePicker() }
        try runLegacyCheck("LibraryUITests.testJSONImportThroughSystemFilePicker") { try checkLibraryUITestsJSONImportThroughSystemFilePicker() }
        try runLegacyCheck("LibraryUITests.testCSVImportSelectsItemTypeAndImportsRows") { try checkLibraryUITestsCSVImportSelectsItemTypeAndImportsRows() }
        try runLegacyCheck("LibraryUITests.testImportValidationKeepsSheetOpenAndLibraryUnchanged") { try checkLibraryUITestsImportValidationKeepsSheetOpenAndLibraryUnchanged() }
        try runLegacyCheck("PortableDeckUITests.testImportPortableDeckSucceeds") { try checkPortableDeckUITestsImportPortableDeckSucceeds() }
        try runLegacyCheck("PortableDeckUITests.testImportAuthoredNeoankiBundle") { try checkPortableDeckUITestsImportAuthoredNeoankiBundle() }
        try runLegacyCheck("PortableDeckUITests.testExportPortableDeckSucceeds") { try checkPortableDeckUITestsExportPortableDeckSucceeds() }
        try runLegacyCheck("PortableDeckUITests.testExportDisabledWithoutDeckSelection") { try checkPortableDeckUITestsExportDisabledWithoutDeckSelection() }
        try runLegacyCheck("PortableDeckUITests.testImportConflictShowsResolutionDialog") { try checkPortableDeckUITestsImportConflictShowsResolutionDialog() }
        try runLegacyCheck("PortableDeckUITests.testImportConflictUseMatchingLocalType") { try checkPortableDeckUITestsImportConflictUseMatchingLocalType() }
        try runLegacyCheck("PortableDeckUITests.testImportConflictImportAsNewType") { try checkPortableDeckUITestsImportConflictImportAsNewType() }
        try runLegacyCheck("PortableDeckUITests.testImportConflictCancel") { try checkPortableDeckUITestsImportConflictCancel() }
    }

    func testLaunchGatingAndAccessibilityJourney() throws {
        if !hasActivityFilters {
            try runSharedLaunchGatingAndAccessibilityJourney()
            return
        }

        try runLegacyCheck("NavigationGatingUITests.testSidebarHiddenDuringStudy") { try checkNavigationGatingUITestsSidebarHiddenDuringStudy() }
        try runLegacyCheck("NavigationGatingUITests.testSidebarHiddenDuringAddItem") { try checkNavigationGatingUITestsSidebarHiddenDuringAddItem() }
        try runLegacyCheck("NavigationGatingUITests.testSidebarHiddenDuringTemplates") { try checkNavigationGatingUITestsSidebarHiddenDuringTemplates() }
        try runLegacyCheck("ImportExportUITests.testImportDisabledDuringStudy") { try checkImportExportUITestsImportDisabledDuringStudy() }
        try runLegacyCheck("ImportExportUITests.testImportDisabledDuringTemplates") { try checkImportExportUITestsImportDisabledDuringTemplates() }
        try runLegacyCheck("NavigationGatingUITests.testStudyButtonShowsDueBadge") { try checkNavigationGatingUITestsStudyButtonShowsDueBadge() }
        try runLegacyCheck("NavigationGatingUITests.testTransferBusyDisablesImport") { try checkNavigationGatingUITestsTransferBusyDisablesImport() }
        try runLegacyCheck("NavigationGatingUITests.testBootstrapFailureShowsSafeErrorState") { try checkNavigationGatingUITestsBootstrapFailureShowsSafeErrorState() }
        try runLegacyCheck("LibraryUITests.testBootstrapFailureShowsSafeErrorState") { try checkLibraryUITestsBootstrapFailureShowsSafeErrorState() }
    }

    var hasActivityFilters: Bool {
        !(ProcessInfo.processInfo.environment["NEOANKI_UI_ACTIVITY_FILTERS"]?
            .split(separator: ",")
            .isEmpty ?? true)
    }

    func runJourneyActivity(
        _ identifier: String,
        _ body: () throws -> Void
    ) rethrows {
        try XCTContext.runActivity(named: identifier) { _ in
            try body()
        }
    }

    private func runLegacyCheck(
        _ identifier: String,
        _ body: () throws -> Void
    ) rethrows {
        let filters = ProcessInfo.processInfo.environment["NEOANKI_UI_ACTIVITY_FILTERS"]?
            .split(separator: ",")
            .map(String.init) ?? []
        guard filters.isEmpty || filters.contains(identifier) else { return }

        try XCTContext.runActivity(named: identifier) { _ in
            try body()
        }
    }
}
