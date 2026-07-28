# Known issues

No unresolved issues are currently recorded.

Last reviewed 2026-07-28, against `cb63309` plus the current worktree.

## Resolved in this worktree

### Window content overflow

The main `NavigationSplitView` now receives the window content area's exact
size through a `GeometryReader`. This breaks the propagation of oversized ideal
heights from conditional detail content and keeps the sidebar list inside the
window. The existing AppKit frame clamp remains responsible for restored
windows that exceed the physical display.

Validated by:

- `AuthoringUITests.testUnassignedScopeEmptyState`
- `LibraryUITests.testDeleteAllUnassignedFromSidebarMenu`
- `LibraryUITests.testDeleteAllUnassignedFromToolbar`

### Selected subdeck hidden by a collapsed ancestor

A deck disclosure now expands whenever the selected deck is one of its
descendants. Creating or navigating to a subdeck therefore keeps the selected
row visible.

Validated by:

- `DeckUITests.testDeleteDeckRemovesSubdecksAndItems`

### Weak Advanced-template interaction coverage

The Advanced section now uses an explicit accessible button and conditionally
creates its content, so collapsed content is genuinely absent from the
accessibility tree. The picker test selects every actual menu label, verifies
the selected value, scopes menu lookup to the picker, and no longer pretends
that every interaction can be saved against two generic text fields.

Validated by:

- `TemplatesAdvancedUITests.testTemplateAdvancedSettingsExpand`
- `TemplatesAdvancedUITests.testTemplateInteractionPickerAllTypes`
