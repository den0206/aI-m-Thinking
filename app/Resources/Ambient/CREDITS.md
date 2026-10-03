# Ambient sound credits

All Ambient Accents recordings are CC0 1.0. They are bundled locally and never fetched at runtime.

## Rain — `rain.m4a`

- Recording: **RAIN on glass window.wav**, Freesound #648529
- Author: **nicoproson**
- Source: https://freesound.org/s/648529/
- License: CC0 1.0
- Processing: Freesound HQ preview, 44–68 s excerpt, 70 Hz one-pole high-pass, level matched to about -23 LUFS, 80 ms fade-in and 300 ms fade-out, AAC 160 kbps.
- aI'm Thinking plays at most 5 seconds from the recording and adds runtime fades.

## Distant thunder — `thunder.m4a`

- Recording: **Distant Thunder 3**, Freesound #581124
- Author: **Fission9**
- Source: https://freesound.org/people/Fission9/sounds/581124/
- License: CC0 1.0
- Processing: Freesound HQ preview (whole recording), about +9.3 dB without clipping, 80 ms fade-in and 300 ms fade-out, AAC 160 kbps.
- aI'm Thinking plays the whole recording (about 8.2 seconds) and adds runtime fades.

## Page turn — `page-turn.m4a`

- Recording: **Page Turn**, Freesound #656546
- Author: **IENBA**
- Source: https://freesound.org/people/IENBA/sounds/656546/
- License: CC0 1.0
- Processing: Freesound HQ preview, first 2.1 s (two page movements), +8 dB with peak limiting, short fade-out, AAC 128 kbps.

## Runtime behavior

Ambient Accents are off by default. When enabled, they can play only while an observed agent is in a Thinking, Writing, or Tool turn. An accent plays after a random 3–8 minutes of accumulated audible agent activity; the count pauses while agents are silent (including permission prompts and quiet tool runs), between turns, and during system sleep, and the same sound never plays twice in a row. Individual sound categories are selected internally according to the current agent state; users do not choose categories.

The Ambient bus follows the existing master Volume and Mute controls. Internal per-sound level and fade timing keep the one-shots from sounding abrupt.

Debug builds expose temporary tuning controls for gain and one-shot preview. Release builds do not expose those controls.
