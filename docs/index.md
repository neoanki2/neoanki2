---
layout: landing
title: Native spaced repetition for Apple devices
description: Model knowledge once, practice it in multiple ways, and let modern FSRS scheduling decide when each review returns.
audience: user
image: /assets/screenshots/template-advanced.png
nav_order: 1
---

<section class="quiet-hero" aria-labelledby="hero-title">
  <div class="quiet-hero-copy">
    <p class="quiet-intro">A native, local-first study tool for Mac, iPhone, and iPad</p>
    <h1 id="hero-title">Structure the idea.<br>Practice the skill.</h1>
    <p class="quiet-lede">NeoAnki2 stores knowledge as structured data—not tiny webpages—then turns it into focused recall and schedules each review with FSRS.</p>
    <div class="quiet-actions">
      <a class="button button-primary" href="{{ '/download/' | relative_url }}">
        <svg viewBox="0 0 24 24" aria-hidden="true"><path d="M12 3v12m0 0 4-4m-4 4-4-4M5 20h14"/></svg>
        Download for Mac
      </a>
      <a class="button button-secondary" href="{{ '/user/' | relative_url }}">Read the guides</a>
    </div>
    <p class="quiet-release-note">Universal Mac app · macOS 14+ · <a href="{{ '/download/' | relative_url }}">installation details</a></p>
    <p class="quiet-caveat">Ad-hoc signed and not yet Apple-notarized. The download page explains the safe first launch.</p>
  </div>

  <figure class="quiet-hero-figure">
    <a class="screenshot-link" href="{{ '/assets/screenshots/template-advanced.png' | relative_url }}" aria-label="Open the Item Type Studio screenshot at full size">
      <img src="{{ '/assets/screenshots/template-advanced.png' | relative_url }}" width="1024" height="708" alt="NeoAnki2 showing a Card setup with structured Question, Answer, Availability, and Learning route settings">
    </a>
    <figcaption><strong>Knowledge has structure.</strong> Fields hold the material; Card setups decide how you practise it.</figcaption>
  </figure>
</section>

<section class="compatibility-note" aria-labelledby="mobile-title">
  <p class="quiet-margin-note">Study anywhere</p>
  <div>
    <h2 id="mobile-title">One native model, adapted for iPhone and iPad.</h2>
    <p>The mobile app has complete study and authoring flows, import and export, optional private iCloud sync, daily reminders, and due-count widgets. Public downloads currently ship for macOS; iPhone and iPad builds still require a maintainer build or TestFlight invitation.</p>
    <a href="{{ '/user/iphone-ipad/' | relative_url }}">Use NeoAnki2 on iPhone or iPad <span aria-hidden="true">→</span></a>
  </div>
</section>

<section class="release-ledger" aria-label="Current release">
  <p><span>Release channel</span><strong>Official macOS builds</strong></p>
  <p><span>Updates</span><strong>Homebrew or GitHub Releases</strong></p>
  <p><span>Architecture</span><strong>Apple silicon + Intel</strong></p>
  <p class="release-ledger-links"><a href="https://github.com/neoanki2/neoanki2/releases/latest">Latest release and checksum</a></p>
</section>

<section class="quiet-thesis" aria-labelledby="thesis-title">
  <p class="quiet-margin-note">Why rebuild spaced repetition?</p>
  <div>
    <h2 id="thesis-title">A card should ask a question, not render a document.</h2>
    <p>NeoAnki2 drops HTML card templates and legacy scheduling baggage. Text, cloze spans, images, audio, video, and numbers remain native values that the Mac can display clearly and accessibly.</p>
  </div>
</section>

<section class="study-sequence" aria-labelledby="sequence-title">
  <header class="sequence-heading">
    <p class="quiet-margin-note">The working rhythm</p>
    <h2 id="sequence-title">Shape. Recall. Schedule.</h2>
  </header>

  <article class="sequence-step">
    <div class="sequence-copy">
      <p class="sequence-verb">Shape</p>
      <h3>Model the idea, not its appearance.</h3>
      <p>Define fields and reusable Card setups once. One item can produce reveal, typed-answer, choice, arrange, record, or cloze practice without duplicating the underlying knowledge.</p>
      <a href="{{ '/user/item-types-and-templates/' | relative_url }}">How item types work <span aria-hidden="true">→</span></a>
    </div>
    <figure class="sequence-figure">
      <a class="screenshot-link" href="{{ '/assets/screenshots/template-advanced.png' | relative_url }}" aria-label="Open the Item Type Studio screenshot at full size">
        <img src="{{ '/assets/screenshots/template-advanced.png' | relative_url }}" width="992" height="688" loading="lazy" alt="NeoAnki2 Item Type Studio mapping structured fields into a Question and Answer">
      </a>
    </figure>
  </article>

  <article class="sequence-step sequence-step-reverse">
    <div class="sequence-copy">
      <p class="sequence-verb">Recall</p>
      <h3>One prompt. One honest decision.</h3>
      <p>The study view removes everything that does not help retrieval. Reveal the answer, compare it with your response, then grade with the mouse or the 1–4 keys.</p>
      <a href="{{ '/user/studying/' | relative_url }}">See the study flow <span aria-hidden="true">→</span></a>
    </div>
    <figure class="sequence-figure">
      <a class="screenshot-link" href="{{ '/assets/screenshots/study-answer.png' | relative_url }}" aria-label="Open the study answer screenshot at full size">
        <img src="{{ '/assets/screenshots/study-answer.png' | relative_url }}" width="1024" height="716" loading="lazy" alt="NeoAnki2 study view with a revealed answer and Again, Hard, Good, and Easy choices">
      </a>
    </figure>
  </article>

  <article class="sequence-step">
    <div class="sequence-copy">
      <p class="sequence-verb">Schedule</p>
      <h3>Memory science stays out of the way.</h3>
      <p>FSRS estimates when a memory needs attention. Your four review choices update the schedule; there is no ease factor to tune and no dashboard demanding attention.</p>
      <a href="{{ '/user/scheduling/' | relative_url }}">Understand the schedule <span aria-hidden="true">→</span></a>
    </div>
    <figure class="sequence-figure">
      <a class="screenshot-link" href="{{ '/assets/screenshots/scheduling-result.png' | relative_url }}" aria-label="Open the scheduling screenshot at full size">
        <img src="{{ '/assets/screenshots/scheduling-result.png' | relative_url }}" width="1024" height="716" loading="lazy" alt="NeoAnki2 library showing one due card and a quiet scheduling summary">
      </a>
    </figure>
  </article>
</section>

<section class="compatibility-note" aria-labelledby="compatibility-title">
  <p class="quiet-margin-note">A deliberate break</p>
  <div>
    <h2 id="compatibility-title">A ground-up alternative, not an Anki-compatible client.</h2>
    <p>NeoAnki2 does not import <code>.apkg</code> or <code>.colpkg</code> files and does not run HTML/CSS card templates. It imports JSON, CSV, authored <code>.neoanki</code> bundles, and portable <code>.neodeck</code> files.</p>
    <a href="{{ '/user/import-export/' | relative_url }}">Review supported formats <span aria-hidden="true">→</span></a>
  </div>
</section>

<section class="quiet-close" aria-labelledby="close-title">
  <div>
    <p class="quiet-margin-note">A quiet desk, ready</p>
    <h2 id="close-title">Ready for your next subject.</h2>
  </div>
  <div class="quiet-actions quiet-close-actions">
    <a class="button button-primary" href="{{ '/download/' | relative_url }}">Download for macOS</a>
    <a class="button button-secondary" href="{{ '/download/' | relative_url }}">Install with Homebrew</a>
  </div>
</section>
