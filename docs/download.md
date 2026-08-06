---
layout: landing
title: Download NeoAnki2
description: Download the current universal macOS release or install NeoAnki2 with Homebrew.
permalink: /download/
---

{% assign release = site.data.release %}

<article class="download-sheet">
  <header class="download-heading">
    <p class="quiet-intro">Current release · {{ release.name }}</p>
    <h1>Install NeoAnki2.</h1>
    <p>Choose Homebrew for automatic upgrades or download the universal DMG directly. Both install the same official build.</p>
  </header>

  <section class="download-option download-option-primary" aria-labelledby="homebrew-title">
    <div>
      <p class="download-label">Recommended</p>
      <h2 id="homebrew-title">Install with Homebrew</h2>
      <p>Homebrew verifies the release checksum, installs NeoAnki2 in Applications, and makes future updates straightforward.</p>
    </div>
    <div>
      <pre class="download-command"><code>brew install --cask neoanki2/tap/neoanki2</code></pre>
      <p class="download-security-note">Because this build is not yet notarized, the cask removes <code>com.apple.quarantine</code> from <code>NeoAnki2.app</code> after installation. It does not disable Gatekeeper or change any system-wide setting. <a href="https://github.com/neoanki2/homebrew-tap/blob/main/Casks/neoanki2.rb">Inspect the cask</a>.</p>
    </div>
  </section>

  <section class="download-option" aria-labelledby="direct-title">
    <div>
      <p class="download-label">Direct download</p>
      <h2 id="direct-title">Download the universal DMG</h2>
      <p>{{ release.name }} · {{ release.size }} · Apple silicon and Intel · macOS 14 or newer.</p>
    </div>
    <div class="download-option-actions">
      <a class="button button-primary" href="{{ release.download_url }}">Download DMG</a>
      <a href="{{ release.checksum_url }}">SHA-256 checksum</a>
      <a href="{{ release.release_url }}">Release notes</a>
    </div>
  </section>

  <aside class="notarization-note" aria-labelledby="first-launch-title">
    <h2 id="first-launch-title">Before the first launch</h2>
    <p>NeoAnki2 is ad-hoc signed and provenance-attested, but it is not yet Apple-notarized. If macOS blocks it, Control-click NeoAnki2 in Applications, choose <strong>Open</strong>, then confirm <strong>Open</strong>. Do not disable Gatekeeper globally.</p>
  </aside>

  <section class="download-details" aria-labelledby="details-title">
    <h2 id="details-title">Release details</h2>
    <dl>
      <div><dt>Version</dt><dd>{{ release.version }}</dd></div>
      <div><dt>Published</dt><dd>{{ release.published_at | date: "%B %-d, %Y" }}</dd></div>
      <div><dt>System</dt><dd>macOS 14+</dd></div>
      <div><dt>Architecture</dt><dd>Universal</dd></div>
      <div><dt>Library</dt><dd>Local to this Mac</dd></div>
      <div><dt>Source</dt><dd><a href="{{ site.source_url }}">Available on GitHub</a></dd></div>
    </dl>
  </section>

  <footer class="download-help">
    <p><strong>Already installed?</strong> Your library remains in place when NeoAnki2 is upgraded.</p>
    <a href="{{ '/user/getting-started/' | relative_url }}">Updates, removal, and troubleshooting <span aria-hidden="true">→</span></a>
  </footer>
</article>
