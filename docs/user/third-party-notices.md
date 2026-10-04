---
title: Third-party software notices
description: Copyright, license, and provenance notices for software used by NeoAnki2.
audience: user
parent: User Guide
nav_order: 43
permalink: /user/third-party-notices/
---

# Third-party software notices

NeoAnki2's scheduling code includes a native Swift port of the FSRS reference
implementation. The following upstream copyright notices, license conditions,
and disclaimers are reproduced in full. They apply to the identified upstream
software and do not imply endorsement of NeoAnki2.

## FSRS reference implementation

Source: [open-spaced-repetition/fsrs-rs](https://github.com/open-spaced-repetition/fsrs-rs/tree/6f5498f8dd1a95c781fcdd4448f28f16dd9e377d),
commit `6f5498f8dd1a95c781fcdd4448f28f16dd9e377d` (manifest version 6.6.2).
NeoAnki2 ports this implementation to Swift; it does not link a Rust crate.

The complete upstream [BSD-3-Clause license](https://github.com/open-spaced-repetition/fsrs-rs/blob/6f5498f8dd1a95c781fcdd4448f28f16dd9e377d/LICENSE)
is reproduced below without alteration:

```text
BSD 3-Clause License

Copyright (c) 2023, Open Spaced Repetition

Redistribution and use in source and binary forms, with or without
modification, are permitted provided that the following conditions are met:

1. Redistributions of source code must retain the above copyright notice, this
   list of conditions and the following disclaimer.

2. Redistributions in binary form must reproduce the above copyright notice,
   this list of conditions and the following disclaimer in the documentation
   and/or other materials provided with the distribution.

3. Neither the name of the copyright holder nor the names of its
   contributors may be used to endorse or promote products derived from
   this software without specific prior written permission.

THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS"
AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE
IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE
DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT HOLDER OR CONTRIBUTORS BE LIABLE
FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL
DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR
SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER
CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY,
OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE
OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
```

## Rand algorithm reference

NeoAnki2's deterministic random/shuffle compatibility code is an independent
Swift implementation of behavior checked against Rust `rand` 0.10.2, including
ChaCha12. No Rust crate is linked or distributed. The upstream Rand project
provides its software under the MIT or Apache-2.0 license; its complete
[MIT notice](https://github.com/rust-random/rand/blob/0.10.2/LICENSE-MIT)
is reproduced here for attribution:

```text
Copyright 2018 Developers of the Rand project
Copyright (c) 2014 The Rust Project Developers

Permission is hereby granted, free of charge, to any
person obtaining a copy of this software and associated
documentation files (the "Software"), to deal in the
Software without restriction, including without
limitation the rights to use, copy, modify, merge,
publish, distribute, sublicense, and/or sell copies of
the Software, and to permit persons to whom the Software
is furnished to do so, subject to the following
conditions:

The above copyright notice and this permission notice
shall be included in all copies or substantial portions
of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF
ANY KIND, EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED
TO THE WARRANTIES OF MERCHANTABILITY, FITNESS FOR A
PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT
SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY
CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION
OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR
IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER
DEALINGS IN THE SOFTWARE.
```

## Apple system frameworks

NeoAnki2 uses frameworks provided by the operating system, including CloudKit
for optional private iCloud sync; AVFoundation for media recording and playback;
NaturalLanguage for local prose sentence splitting; PhotosUI and UIKit for
media, camera, and file interactions; UserNotifications for local reminders;
and WidgetKit for due-card widgets. These system frameworks are not copies of
third-party content libraries distributed by NeoAnki2.

The app does not bundle a dictionary or study-content catalogue. Installed
vocabulary packages and study files are chosen by the user; any source-specific
attribution supplied with those files belongs to that content.

**Related:** [Support](../support/) · [Privacy policy](../privacy/)
