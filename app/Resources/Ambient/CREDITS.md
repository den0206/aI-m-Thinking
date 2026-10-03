# Ambient sound credits

All Ambient Accents recordings are CC0 1.0. They are bundled locally and never fetched at runtime.

## Rain — `rain.mp3`

- Recording: **Light rain on window**, Freesound #648529
- Author: **nicoproson**
- Source: https://freesound.org/s/648529/
- License: CC0 1.0
- Bundled derivative source: `xinchenok/izumi-sagiri-room`
- Processing in that project: 44–68 s excerpt, high-pass 70 Hz, EBU R128 -23 LUFS, short fades, 48 kHz stereo MP3.
- aI'm Thinking plays at most 9 seconds from the recording and adds runtime fade/reverb.

## Distant thunder — `thunder.ogg`

- Recording: **Distant Thunder 3**, Freesound #581124
- Author: **Fission9**
- Source: https://freesound.org/people/Fission9/sounds/581124/
- License: CC0 1.0
- Bundled derivative source: `13rac1/StillFlow` (`thunder-distant-boom.ogg`)
- The source project applies a level boost. aI'm Thinking limits playback to 8 seconds and adds runtime fade/reverb.

## Page turn — `page-turn.mp3`

- Recording: **Page Turn**, Freesound #860360
- Author: **sokworks**
- Source: https://freesound.org/people/sokworks/sounds/860360/
- License: CC0 1.0
- Bundled derivative source: `irreal/get-ready-for-school`
- That project extracts the action, removes pauses, adjusts level, and adds short edge fades.

## Writing — `writing.mp3`

- Recording: **Pencil writing on paper (1 stroke, Take B)**, Freesound #632472
- Author: **ani_music**
- Source: https://freesound.org/people/ani_music/sounds/632472/
- License: CC0 1.0
- Bundled derivative source: `irreal/get-ready-for-school`
- That project extracts the action, removes pauses, adjusts level, and adds short edge fades.

## Runtime behavior

Ambient Accents are off by default. When enabled, they can play only while an observed agent is actively Thinking, Writing, or using a Tool. The interval is randomized between roughly 5 and 15 minutes of continuous activity. Individual sound categories are selected internally according to the current agent state; users do not choose categories.

The Ambient bus follows the existing master Volume and Mute controls. Internal per-sound level, fade timing, and light room reverb keep the one-shots from sounding abrupt.

Debug builds expose temporary tuning controls for gain, reverb, interval scale, and one-shot preview. Release builds do not expose those controls.
