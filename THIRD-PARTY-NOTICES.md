# Third-Party Notices

Seedbed builds on the third-party components below. Each is distributed under
its own license, reproduced or referenced here.

This file ships inside the DMG alongside the app, because the MIT license
requires its copyright and permission notice to travel with copies of the
software, and Sparkle is embedded in the bundle as a framework.

| Component | Use | License |
|---|---|---|
| [Sparkle](https://sparkle-project.org) | Updating an installed copy from the signed appcast | MIT (+ bundled BSD and MIT components, below) |
| [Sentry Cocoa SDK](https://github.com/getsentry/sentry-cocoa) | Crash reporting, opt-in and off unless the build carries a DSN | MIT |
| [Inter](https://github.com/rsms/inter) | Interface font bundled with the local web UI | SIL Open Font License 1.1 |
| [JetBrains Mono](https://github.com/JetBrains/JetBrainsMono) | Monospaced font bundled with the local web UI | SIL Open Font License 1.1 |

The Python core has no third-party runtime dependencies: it is the standard
library plus `tomllib`, which is part of Python 3.11.

Seedbed also uses Apple system frameworks (AppKit, SwiftUI, Security,
ApplicationServices), which ship with macOS and are governed by the macOS
Software License Agreement.

The fonts' full license texts are in the repository beside the fonts
themselves, at `promptlib/web/fonts/Inter-LICENSE.txt` and
`promptlib/web/fonts/JetBrainsMono-LICENSE.txt`. They are reproduced there
rather than here because that is where a reader who has the font file will look
for them.

---

## MIT License

Applies to Sparkle (© 2006–2013 Andy Matuschak, © 2009–2013 Elgato Systems
GmbH, © 2011–2014 Kornel Lesiński, © 2015–2017 Mayur Pawashe, © 2014 C.W.
Betts, © 2014 Petroules Corporation, © 2014 Big Nerd Ranch) and to the Sentry
Cocoa SDK (© 2015 Sentry).

```
Permission is hereby granted, free of charge, to any person obtaining a copy of
this software and associated documentation files (the "Software"), to deal in
the Software without restriction, including without limitation the rights to
use, copy, modify, merge, publish, distribute, sublicense, and/or sell copies of
the Software, and to permit persons to whom the Software is furnished to do so,
subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS
FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR
COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER
IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN
CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.
```

## Components bundled inside Sparkle

Sparkle's own license file carries these, and they travel with the framework
embedded in the app.

**bsdiff 4.3** (`bspatch.c`, `bsdiff.c`), © 2003–2005 Colin Percival, BSD
2-clause:

```
Redistribution and use in source and binary forms, with or without
modification, are permitted providing that the following conditions
are met:
1. Redistributions of source code must retain the above copyright
   notice, this list of conditions and the following disclaimer.
2. Redistributions in binary form must reproduce the above copyright
   notice, this list of conditions and the following disclaimer in the
   documentation and/or other materials provided with the distribution.

THIS SOFTWARE IS PROVIDED BY THE AUTHOR ``AS IS'' AND ANY EXPRESS OR
IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED
WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE
ARE DISCLAIMED.  IN NO EVENT SHALL THE AUTHOR BE LIABLE FOR ANY
DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL
DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS
OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION)
HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT,
STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING
IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE
POSSIBILITY OF SUCH DAMAGE.
```

**sais-lite** (`sais.c`, `sais.h`), © 2008–2010 Yuta Mori, MIT. The text is the
MIT license reproduced above.

## SIL Open Font License 1.1

Applies to Inter (© 2016 The Inter Project Authors) and JetBrains Mono
(© 2020 The JetBrains Mono Project Authors). Both fonts are bundled unmodified
with the local web UI and are not embedded in the macOS app, which uses Apple's
system faces. The full license text accompanies each font file in
`promptlib/web/fonts/`, and is published at
<https://openfontlicense.org>.

---

## Keeping this file honest

`macos/Package.resolved` is the authority for which versions are linked; this
file is the authority for what their licenses require. When a dependency is
added, removed or replaced, update the table here in the same commit, and check
whether the new component's license needs its text reproduced rather than
referenced. `tests/test_third_party_notices.py` compares the table against
`Package.resolved` and fails when they disagree.
