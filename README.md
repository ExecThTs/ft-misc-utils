A directory of all the miscellaneous Lua scripts I wrote for various FamiTracker / 0CC-FamiTracker utilities.

Some of the scripts will only run on Lua 5.3, some also require [this](https://github.com/HertzDevil/luaFTM) fairly incomplete Lua library for reading / writing FamiTracker modules. Most of these scripts are originally for personal use only; do not expect any comments or help text in them. They may also differ largely in style, and may not even be reusable outside a few contexts.

- `organ`: Generates drawbar organ instruments for the N163.
- `tuplet`: Calculates the delay effects required for tuplets in any tempo or groove setting.
- `un0cc`: Scripts to convert 0CC-FamiTracker features into vanilla FamiTracker equivalents.
  - `0xy`: Converts instruments using arpeggio schemes into individual instruments and arpeggio sequences. The actual `0xy` commands themselves are unaffected.
  - `Lxx`: Converts delayed note release effect commands into note releases plus Gxx commands.
- `wavegen`: N163 instrument sampler for loopable WAV files.

All these scripts are licensed with the MIT License where unspecified otherwise.