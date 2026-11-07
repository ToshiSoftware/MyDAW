# Third-party notices

MyDAW itself is MIT licensed (see LICENSE). It uses the following third-party
components.

## VST 3 SDK

- Source: https://github.com/steinbergmedia/vst3sdk (not included in this
  repository; `ThirdParty/vst3sdk` is cloned by the developer)
- License: MIT License, Copyright (c) Steinberg Media Technologies GmbH
- Used for: hosting VST3 plug-ins (`VST3Host/`, linked into MyDAW.app)
- VST is a registered trademark of Steinberg Media Technologies GmbH.

## LAME 3.100

- Source: https://lame.sourceforge.io/ (downloaded and checked by SHA-256 in
  `scripts/build-lame.sh`)
- License: GNU Lesser General Public License (LGPL) version 2 or later
- Used for: MP3 export. It ships as a separate, replaceable dynamic library
  (`MyDAW.app/Contents/Frameworks/libmp3lame.0.dylib`), loaded at run time;
  its license text is in `MyDAW.app/Contents/Resources/LAME-COPYING.txt`.
  You may replace the library with your own build of LAME.

## Trademarks

Apple, Mac, macOS and Audio Unit are trademarks of Apple Inc. Other product
names that appear in source comments are trademarks of their respective
owners and are mentioned only to describe compatibility.
