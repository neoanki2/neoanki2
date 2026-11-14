---
title: Local Apple AI research and potential NeoAnki2 features
description: On-device Apple language-model capabilities, English/Ukrainian/Japanese requirements, local speech, feature proposals, and an implementation and evaluation plan.
audience: developer
permalink: /audits/apple-local-ai-2026-11-13/
---

# Local Apple AI research and potential NeoAnki2 features

**Research date: November 13, 2026. Status: research and proposed design.**

This report consolidates the discussion about example sentences, text-to-speech,
contextual explanations, and other uses of Apple's local language model. It uses
English, Ukrainian, and Japanese as reference requirements while keeping the
proposed architecture open to additional languages.

The recommendation is to combine existing local dictionaries with Apple speech
synthesis, then add optional contextual explanations, progressive hints, and
contrasting examples. Apple's language model can support English and Japanese
on eligible devices. Ukrainian currently requires a different generation provider.
Ordinary dictionary lookup and review should work independently of model availability.

## 1. Scope and evidence

Apple documentation establishes API behavior and advertised capabilities. Feature
ideas, architecture, priorities, and evaluation criteria below are proposals for
NeoAnki2, not evidence of implemented or shipped behavior.

Repository inspection found:

- The Swift package supports macOS 14 and iOS 17, below the Foundation Models minimum.
- Vocabulary packs already store lexical forms, senses, examples, pronunciation,
  and provenance, and can ingest local Tatoeba data.
- A search of `Sources` and `Tests` found no `FoundationModels` or
  `AVSpeechSynthesizer` integration at the research date.

No model inference, latency, battery, pronunciation-quality, or physical-device
acceptance tests were performed for this report. Earlier CLI inspection listed
English voices, Ukrainian Lesya, and Japanese Kyoko on the research Mac; that is
an availability observation, not a pronunciation or offline-reliability benchmark.

Related repository material:

- [Offline vocabulary packs]({{ '/OFFLINE_VOCABULARY/' | relative_url }}).
- [Migaku competitor research]({{ '/audits/migaku-competitor-2026-11-11/' | relative_url }}).
- [Architecture]({{ '/ARCHITECTURE/' | relative_url }}).
- [Developer guide]({{ '/user/developer/' | relative_url }}).

## 2. What Apple's local model is

The Foundation Models framework exposes an on-device text model through
`SystemLanguageModel.default`. Applications create a `LanguageModelSession`,
provide instructions and relevant input, and request a response. Apple updates
the underlying model through OS updates, so output and quality can change.
[SystemLanguageModel](https://developer.apple.com/documentation/foundationmodels/systemlanguagemodel).

Apple documents text understanding, summarization, extraction, rewriting,
classification, and creative generation. These make short, bounded learning tasks
plausible. They do not establish teaching accuracy, reliable reasoning, or a
complete dictionary. [Capabilities and generation](https://developer.apple.com/documentation/foundationmodels/generating-content-and-performing-tasks-with-foundation-models).

The framework also supports guided generation into Swift types and tools that
query application data. Structured output helps rendering and validation;
it does not prove that the generated explanation is correct.
[Guided generation](https://developer.apple.com/documentation/foundationmodels/generating-swift-data-structures-with-guided-generation),
[tool calling](https://developer.apple.com/documentation/foundationmodels/expanding-generation-with-tool-calling).

### Local inference versus other framework providers

The current Foundation Models framework also supports cloud and third-party
providers. Using the framework alone therefore does not establish offline behavior.
The local implementation should explicitly select `SystemLanguageModel` and use
local data sources. Network-backed tools would change the privacy and connectivity
properties. [Framework overview](https://developer.apple.com/foundation-models-framework/).

The operating system manages the Apple model assets. Initial downloads require
connectivity; generation can subsequently run offline when the model is ready.
No external model-service API key is needed for this local path. Cloud generation,
cloud sync, and downloading dictionaries remain separate operations.

## 3. Device, OS, and language requirements

`SystemLanguageModel` is available starting with iOS 26 and macOS 26. Compile-time
API availability is only the first gate: hardware eligibility, Apple Intelligence
settings, region, and model readiness also matter. Check `availability` at runtime
and refresh it when relevant conditions change.
[API availability](https://developer.apple.com/documentation/foundationmodels/systemlanguagemodel).

Common eligible devices include M1-or-newer Macs, iPhone 15 Pro/Pro Max, and
iPhone 16-or-later models. Apple's current list includes additional devices;
do not maintain eligibility by comparing model names in application code. Device
and Siri language settings and supported regions can affect availability.
[Apple Intelligence requirements](https://support.apple.com/en-us/121115).

NeoAnki2 can retain its existing OS minimums and put optional generation behind
availability checks. Older devices can still use dictionaries, saved explanations,
saved audio, and supported system speech.

### Reference language matrix

| Capability | English | Ukrainian | Japanese |
| --- | --- | --- | --- |
| Local dictionary/corpus lookup | Feasible | Feasible | Feasible; needs segmentation |
| Apple on-device text generation | Supported language; evaluate quality | Not currently listed as supported | Supported language; evaluate quality |
| Apple generation of explanations in this language | Supported language | Requires another provider | Supported language |
| Apple system TTS | Available voices | Available voices | Available voices |
| Downloaded multilingual text model | Candidate alternative | Important alternative | Candidate alternative |

Language support for input, output, dictionary definitions, and translations must
be checked separately. An English prompt requesting Ukrainian output does not
make Ukrainian supported. Use `supportsLocale(_:)` and `supportedLanguages` where
available rather than freezing the table into application logic. Model and OS
versions may differ. [Language handling](https://developer.apple.com/documentation/foundationmodels/supporting-languages-and-locales-with-foundation-models),
[current supported languages](https://support.apple.com/en-us/121115).

## 4. Finding and creating example sentences

### Retrieve existing examples locally

Use imported dictionary examples or a downloaded corpus before generating new
text. Tatoeba distributes sentences, translation links, and audio metadata;
coverage varies and audio has separate licensing information.
[Tatoeba downloads](https://tatoeba.org/en/downloads).

NeoAnki2's existing pack pipeline already preserves dictionary examples and can
enrich entries from local Tatoeba files. The current generic tokenizer groups
consecutive letters/numbers; it needs additional segmentation to find individual
words in ordinary unspaced Japanese sentences. Matching surface forms also does
not establish the intended dictionary sense.

Proposed retrieval order:

1. Prefer examples already associated with the selected dictionary sense.
2. Retrieve corpus candidates using canonical and inflected forms.
3. Rank by meaning relevance, sentence completeness, length, and learner vocabulary.
4. Present a small selection with provenance and an editable target span.
5. Offer generation when examples are missing or unsuitable.

Keep the original corpus text intact. A simplified or rewritten version is a
derived example and should be labeled accordingly.

### Generate new examples

Provide a word or expression, its intended sense and part of speech, desired
register, target language, explanation language, and approximate learner level.
Request a small number of short sentences. Where useful, include a bounded set
of known vocabulary and a topic preference.

A proposed instruction could ask for three distinct contexts that make the
meaning inferable. For *bookkeeping*, describing recording income and expenses
is more informative than merely saying someone studies bookkeeping.

Validate that the target occurs in an acceptable form and that the sentence is
complete. Language analysis should determine inflections and spans; asking the
model for an exact character count or offset is unnecessarily fragile.

## 5. Potential learning features

All features in this section are proposed applications to evaluate.

| Feature | Learner benefit | Proposed boundary |
| --- | --- | --- |
| Explain in context | Understand what a word means in the current sentence | Ground in selected dictionary senses and source text |
| Explain a phrase | Understand idioms, phrasal verbs, or fixed expressions | Preserve the whole expression as a target |
| Explain grammar | Understand a tense, inflection, particle, or construction | Treat output as editable guidance; verify language accuracy |
| Progressive hints | Retrieve the answer with less immediate disclosure | Generate hints separately from the full answer |
| Contrast meanings | Distinguish senses of the same spelling | Use explicit dictionary sense identifiers |
| Compare confusing words | Learn differences through paired examples | Identify the particular distinction being taught |
| Simplify an example | Read a sentence closer to the learner's level | Preserve the intended sense and label the rewrite |
| Generate cloze exercises | Practice recall from useful context | Validate cloze ranges with ordinary application code |
| Generate questions | Practice meaning through short questions | Keep the expected answer and alternatives reviewable |
| Discuss an answer | Understand why an answer fits or misses the meaning | Feedback is advisory; learner controls review grade |
| Generate dialogues | Practice several words in a coherent exchange | Use short turns and explicit target vocabulary |
| Generate short reading | Revisit recently learned words in context | Measure vocabulary constraints rather than trusting a prompt |
| Suggest mnemonics | Make a difficult item more memorable | Label associations as invented; never invent etymology as fact |
| Suggest tags and organization | Reduce repetitive authoring work | Preview changes before applying them |
| Draft cards from a passage | Turn selected text into editable learning items | Preserve source context; validate ordinary item contracts |

### First feature: Explain in context

Example input:

> Word: charge  
> Sentence: I need to charge my phone before leaving.  
> Selected meaning: supply electrical energy to a battery.  
> Explanation language: English.

Illustrative desired output, not a recorded model result:

> Here, **charge** means to supply electrical energy to the phone's battery.
> It is a verb. A common pattern is **charge + device**.
> Compare: “The restaurant charged me $20,” where it means asking for payment.

The initial response should answer the immediate question in a few sentences.
Optional follow-ups can show grammar, a simpler paraphrase, or contrasting usage.
Keep the original sentence visible so the explanation remains anchored to it.

### Progressive hints

Use an explicit ladder: contextual clue, narrower semantic clue, then answer.
For a production card, early hints must avoid spelling out the target. For a
meaning card, they must avoid simply repeating the answer. Check for obvious
answer leakage before showing a hint. Record hint use separately if the product
later needs it; do not silently convert it into an FSRS grade.

### Personalized examples and short reading

The application could select recently learned words, frequently confused pairs,
and a small sample of known words to supply as context. The model does not
automatically know the user's library or learning history.

After generation, tokenize the text and compare it with the learner-vocabulary
model. “Only one new word” is a measurable constraint, not a guaranteed result
of prompting. Where lexical tracking is incomplete, describe difficulty as an
estimate. Avoid sending a full review history when a few relevant facts suffice.

### Features to defer

Open-ended tutoring, automatic grading, and complete curricula need substantially
more evaluation than short explanations. Reliable pronunciation scoring requires
speech-specific components. Text generation alone cannot hear a learner's speech,
certify pitch accent, or establish language competence.

## 6. Complementary local speech

Apple's `AVSpeechSynthesizer` generates speech on-device independently of the
Foundation Models framework. It can play an utterance immediately or return audio
buffers for storage. Voice selection, language, and speaking rate are configurable.
Its API predates NeoAnki2's current OS minimums. Additional voices may need an
initial download. [Speech synthesis](https://developer.apple.com/documentation/avfoundation/speech-synthesis),
[audio-buffer generation](https://developer.apple.com/documentation/avfaudio/avspeechsynthesizer/write%28_%3Atobuffercallback%3A%29).

Proposed behavior:

- Provide separate playback for the target word and the sentence.
- Enumerate available voices rather than assuming every system voice is exposed.
- Store language, voice identifier, speaking rate, source text, and generation
  provenance alongside reusable audio where the feature needs persistence.
- Invalidate derived audio when its source text changes.
- Keep display text separate from any pronunciation override.
- Prefer verified native recordings when available for pronunciation teaching.

Reference requirements:

| Language | Important cases |
| --- | --- |
| English | Heteronyms such as *read*, stress differences, names, abbreviations, dialect selection |
| Ukrainian | Lexical stress, inflected forms, proper names, apostrophes, optional stress annotations |
| Japanese | Ambiguous kanji readings, names, conjugated forms, counters, and phrase context |

Evaluate words and sentences independently. A pleasant sentence voice may still
mispronounce an isolated ambiguous word. TTS is an additional provider capability,
not evidence that the text model supports the language.

## 7. Proposed integration design

### Provider boundary

Introduce a shared application-level text-generation interface with adapters for
Apple's local model and, later, optional downloaded or cloud models. Keep speech
behind a separate interface. Model availability should describe the requested
operation and language combination, not a single global “AI available” flag.

Suggested text operations are `explainInContext`, `generateExamples`,
`generateHints`, `compareUsage`, and `simplifySentence`. These are design names,
not existing API endpoints. No public HTTP API or file-format change is implied
by this report.

### Bounded request and structured result

A request should contain the exact source sentence, selected span, lemma or
expression, relevant dictionary sense identifiers and definitions, language tags,
task, and bounded preferences. Optional learner context should be deliberately
selected by application code.

For an explanation, a small result could contain:

```json
{
  "contextualMeaning": "Supply electrical energy to the phone's battery.",
  "usageNote": "A verb, commonly followed by the device being charged.",
  "contrast": "A restaurant charging money uses a different meaning.",
  "needsMoreContext": false
}
```

The application owns source and sense references; it should not trust invented
references returned by the model. A self-reported confidence number is not a
validated correctness score. Guided generation controls structure, while normal
validation checks required fields, limits, target occurrences, and references.

### Dictionary grounding and tools

Retrieve known required dictionary information directly before calling the model.
Reserve tool calling for genuinely optional follow-up lookups, such as fetching
another sense or finding a previously confused word. Apple supports tools that
query local application data. Keep initial tools read-only, bounded, and scoped
to the selected task. [Tool calling](https://developer.apple.com/documentation/foundationmodels/expanding-generation-with-tool-calling).

Imported sentences and dictionary text are task data, not trusted instructions.
A passage telling the model to ignore its instructions must not grant access to
unrelated notes or authorize mutations. Dictionary grounding reduces unsupported
claims but cannot guarantee correct teaching content.

### Sessions and context

Apple currently documents a 4,096-token context window for the on-device model.
Instructions, schemas, tools, inputs, outputs, and prior turns consume that budget.
Use a fresh session for independent tasks and a bounded transcript for follow-ups.
Do not put an entire dictionary or deck into the prompt. Newer introspection APIs
should be availability-gated. [Context management](https://developer.apple.com/documentation/foundationmodels/managing-the-context-window).

Prevent simultaneous requests on the same session. Cancel obsolete work when the
learner moves to another card; never attach a late result to the next card.

### Persistence and manual edits

Distinguish transient assistance from saved authored content. A displayed hint
need not become a card field. Accepting an explanation should create ordinary
editable content with provenance through existing authoring boundaries.

Suggested cache identity includes task, source-text hash, target and sense IDs,
dictionary version, input/output languages, prompt version, provider, and available
model identity. Preserve creation time and relevant OS version. Mark stale results
when inputs change; do not overwrite manual edits. Persist accepted content so it
can remain useful when generation is unavailable. Any sync or export behavior
should follow the content's existing policy and make provenance portable.

## 8. Reliability and failure behavior

| Condition | Proposed behavior |
| --- | --- |
| Older OS or ineligible device | Keep lookup, editing, saved material, and review available |
| Model assets not ready | Explain readiness and allow a later attempt |
| Unsupported input/output language | Offer a configured alternative or dictionary-only assistance |
| Insufficient context or ambiguous sense | Let the learner select a sense or supply context |
| Refusal or guardrail error | Report that assistance could not be generated; preserve the input |
| Context budget exceeded | Reduce context deliberately or start a bounded fresh task |
| Cancellation or interruption | Preserve the card and avoid applying partial content |
| Invalid generated content | Reject it as a draft; preserve the editable source |
| Voice unavailable | Allow text-only use or another installed voice |

Apple's local model has guardrails and may refuse material encountered in real
books, subtitles, or dictionaries. Test ordinary educational contexts that include
sensitive vocabulary. Handle documented errors without weakening constraints or
silently switching to a cloud provider.
[Guardrails and refusals](https://developer.apple.com/documentation/foundationmodels/improving-the-safety-of-generative-model-output).

“Generated on this device” should accurately describe the selected path. Sending
prompts to a cloud fallback must be an explicit user choice. Do not log full
personal passages by default. Local inference does not imply that saved content
is excluded from an already-enabled sync policy.

## 9. Alternatives for unsupported languages or devices

| Approach | Useful property | Tradeoff |
| --- | --- | --- |
| Dictionary/corpus only | Predictable offline reference material | Coverage and customization limits |
| Generate on Mac, then sync accepted content | Phone reviews without hosting a model | New material requires generation and transfer |
| Phone requests generation from a reachable Mac | Inference remains on the user's hardware | Mac must be awake and reachable; phone is not independently offline |
| Downloaded multilingual model | Can cover Ukrainian and additional languages | Downloads, memory, battery, maintenance, and language evaluation |
| Optional cloud text generation plus local TTS | Broad generation options with local playback | Network dependency, data transfer, and usage charges |

Qwen3 is one documented multilingual candidate covering English, Ukrainian, and
Japanese. It is an example for evaluation, not a claim to be the best current
model. Ollama offers local Mac integration, and MLX Swift examples demonstrate
local generation on Mac and iOS. Model size and acceptable latency must be tested
on target hardware. [Qwen3](https://qwenlm.github.io/blog/qwen3/),
[Ollama API](https://docs.ollama.com/api/introduction),
[MLX Swift examples](https://github.com/ml-explore/mlx-swift-examples).

For non-Apple speech, Kokoro lists English and Japanese voices but no Ukrainian
voice in the referenced catalog. A Ukrainian Piper model is available. Cloud
speech providers are another optional route. These are separate candidates to
evaluate rather than dependencies required for the first Apple implementation.
[Kokoro voices](https://huggingface.co/hexgrad/Kokoro-82M/blob/main/VOICES.md),
[Ukrainian Piper model](https://huggingface.co/rhasspy/piper-voices/blob/main/uk/uk_UA/ukrainian_tts/medium/MODEL_CARD).

## 10. Migaku comparison

Migaku documents contextual explanations, sentence examples, native recordings,
sentence mining, TTS, and AI sentence generation. Its FAQ describes fetching an
example and synthesizing audio through the card-creation wand. Its changelog
documents customizable sentence-generation prompts, historically names Google
TTS, and describes downloading card media for offline review.
[Goals FAQ](https://migaku.com/faq/goals),
[changelog](https://migaku.com/blog/changelog).

These sources do not establish Migaku's complete current backend or prove that
new generation runs on-device. Offline review of saved audio and explanations
is different from offline creation. NeoAnki2 can combine the same kinds of learner
benefits with explicit per-operation local/cloud provider choices. See the
[separate competitor report]({{ '/audits/migaku-competitor-2026-11-11/' | relative_url }})
for the broader product scope.

## 11. Evaluation plan

### Language fixtures

Create a curated set of sentences and selected meanings, including ambiguous and
insufficient-context cases. Native-speaker or qualified language review is needed
to assess semantic and grammatical quality; exact output strings are unsuitable
as the main generation test.

| Language | Required evaluation examples |
| --- | --- |
| English | Polysemy, phrasal verbs, idioms, homographs, countability, tense, register |
| Ukrainian | Unsupported Apple generation path, local speech, inflection, stress, apostrophes, alternative-provider quality |
| Japanese | Segmentation, conjugation, particles, ambiguous readings, politeness, expression boundaries |
| Cross-language | Different source/definition/explanation languages, mixed scripts, proper names, missing translations |

### Measured outcomes

- Meaning accuracy and relevance to the selected sense.
- Grammar accuracy and usefulness of the explanation.
- Naturalness and contextual informativeness of generated examples.
- Target preservation and compliance with vocabulary/difficulty constraints.
- Answer leakage in hints and invalid cloze targets.
- Pronunciation accuracy for isolated words and complete sentences.
- Time to first useful output and completion, including cold and warm requests.
- Memory, energy, interruption, and cancellation behavior on target devices.
- Correct association of results after rapid navigation or edits.
- Readiness, unsupported-language, refusal, and context-limit handling.

Set acceptance thresholds after measuring a baseline. Evaluate supported OS/model
versions separately and rerun the language fixtures when the system model changes.
Avoid declaring universal language support or guaranteed proficiency levels from
a few successful examples.

Headless unit tests can verify routing, state transitions, cancellation, cache
invalidation, provenance, validation, and protection of manual edits. Model-quality
evaluation is a separate exercise. Follow the repository's desktop-isolation
rules for any later device or UI verification.

## 12. Proposed delivery sequence

| Stage | Deliverable | Evidence needed before expanding |
| --- | --- | --- |
| 1 | Capability discovery and local Apple TTS | Correct voice/language handling and persistent audio where needed |
| 2 | Explain in context for English and Japanese | Reviewed explanations grounded in dictionary senses |
| 3 | Progressive hints and contrasting examples | Useful hints without answer leakage; correct meaning distinctions |
| 4 | Sentence generation and simplification | Target preservation, naturalness, and measured difficulty |
| 5 | Optional alternative provider for Ukrainian | Clear routing plus reviewed Ukrainian outputs |
| 6 | Personalized reading/dialogues and answer discussion | Reliable vocabulary tracking, bounded context, advisory feedback |

The first generation prototype should use selected source text and dictionary
data already available to the app. Validate that narrow workflow before adding
an open-ended assistant or expanding public contracts. Retain ordinary manual
authoring and local review throughout.

## 13. Decisions still to make

- Whether explanations are ephemeral by default or saved through an explicit action.
- Which explanation languages and language pairs receive evaluated support first.
- Whether alternative models are user-configured, bundled, downloaded, or Mac-hosted.
- How learner vocabulary is represented across inflections, expressions, and senses.
- Which generated assets sync and how their provenance appears in exports.
- What latency, battery, and language-quality thresholds justify enabling a feature.

No provider was installed, model downloaded, application code changed, or feature
enabled as part of saving this report.
