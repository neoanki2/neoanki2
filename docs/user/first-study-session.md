---
title: First study session
description: Create one Basic item and complete a tested prompt-reveal-grade loop in five minutes.
nav_order: 2
parent: User Guide
---

# Your first five-minute success

The guided in-app steps take about five minutes. Cloning and the first compile
depend on network and Mac speed, so complete them before starting the timer.

## Before the five-minute timer

You need macOS 14 or newer and developer tools that provide Git and Swift 6.
For the full checks and recovery steps, use [Getting
started](../getting-started/). From a directory where you keep source code, the
complete clone-and-launch path is:

```bash
git clone https://github.com/neoanki2/neoanki2.git
cd neoanki2
./Scripts/run-app.sh
```

Expected result: the build ends with **App bundle ready at
.../.build/NeoAnki2.app** and **Launching NeoAnki2...**, then the app opens at
**All Decks**. A fresh library has no sample items.

Start the timer once that window is open. This path deliberately skips deck
setup and advanced card design: one Basic item is enough to complete a real
review.

## 1. Add one thing to remember

1. Choose **Add Item** in the empty state.
2. Leave **Type** set to **Basic**.
3. Enter `Capital of France` in **Front**.
4. Enter `Paris` in **Back**.
5. Choose **Save**.

Expected result: the form closes and an item row titled **Capital of France**
appears. It reports one generated card. The starter Basic type has one template,
so saving this item creates one study card; this exact one-item/one-card result
is covered by the onboarding flow test.

If **Save** is disabled, both Front and Back need nonblank text. If **Add Item**
or Basic is missing, go to [Troubleshooting](../troubleshooting/).

## 2. Recall before revealing

1. Choose **Study**. Its due count should be `1`.
2. Read **Capital of France** and answer from memory before using the controls.
3. Choose **Show Answer**, or press Space or Return.

Expected result: **Paris** is revealed and the four grade choices become
available. Grades cannot be used before reveal.

## 3. Record the result

Choose **Good** or press `3` if you recalled Paris correctly without unusual
difficulty.

Expected result: NeoAnki2 shows **Session Complete** with one card reviewed.
Choose **Done** to return to the library. **Study** is now disabled for this
scope because no card is currently due.

That is a complete learning loop:

1. the item stored the fact;
2. its Basic template generated a retrieval card;
3. the session asked you to recall before revealing; and
4. the Good grade updated that card's memory state and removed it from the
   current due queue.

The core flow tests assert one due card before grading, one review record after
grading Good, and zero cards due afterward. The UI study test performs the same
add, reveal, Good, complete sequence.

## What to do next

- Add a few more focused facts with [Authoring items](../authoring-items/).
- Create decks only when organization helps; decks do not change card content
  or scheduling.
- During later reviews, use **Again**, **Hard**, **Good**, and **Easy** to
  describe the quality of recall—not how much you like the item.

---

**Next:** [Understand items, templates, cards, and reviews](../concepts/)

**Related:** [Studying in detail](../studying/) · [Shortcuts and accessibility](../shortcuts-accessibility/)
