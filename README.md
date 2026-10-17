# pop

A [Windower 4](https://www.windower.net/) addon for Final Fantasy XI that
watches for a monster to spawn using Wide Scan, tells you the moment it
appears, and keeps an eye on it until it dies.

It is built for camping Notorious Monsters: give it the name or index of the
mob you are waiting on, go do something else, and let the chime tell you when
it pops.

## What it does

- **Scans on a timer.** pop requests a Wide Scan every few seconds and checks
  the results for the mobs you asked for, so you do not have to keep opening
  the Wide Scan menu yourself.
- **Matches by name or index.** Targets can be a full name, a wildcard pattern
  such as `valkurm*`, or a hex entity index such as `0x00f8`. Several targets
  can be given at once and are checked in priority order against each scan.
- **Alerts you.** When a target is found, pop plays a short chime and logs the
  mob's name and index to the chat window.
- **Shows how long you have waited.** An on-screen timer counts up from the
  start of each search. When the mob is found it stops, turns blue, and stays
  on screen for five seconds. It starts centered near the top of the screen
  and can be dragged anywhere; the position is remembered.
- **Counts down to an expected pop.** Add a number of seconds after the
  targets, such as `//pop 0x00f8 300`, and the timer shows elapsed against
  expected time. It turns yellow with 15 seconds to go, orange with 5 while
  beeping once per second, and red once the expected time has passed. The
  beeps stop as soon as the mob pops or the expected time passes.
- **Tracks it.** The found mob is Wide Scan tracked, and its distance, HP
  percentage, and claim status are reported whenever any of them change.
  Distance comes from the tracking data the server sends, so it works across
  the whole zone; HP and claim are available once the mob is within normal
  entity range.
- **Optionally targets it.** Once the mob is in range, pop can put your cursor
  on it, either by sending the game's `/target` command or by injecting the
  client-side lock-on packet for an exact match.
- **Knows when it is over.** Tracking ends when the mob dies in front of you,
  when the client drops the Wide Scan track, or (with tracking off) when the
  mob disappears from the scan results. With looping enabled, the search then
  starts over for the same list, ready for the next spawn window.
- **Stops cleanly.** `//pop stop` or zoning cancels everything.

Wide Scan has to be available to your character. Beastmaster and Ranger get
the full range; other jobs can use it with a much shorter reach.

## Installation

1. Download or clone this repository into your Windower addons folder so that
   the file lives at `Windower/addons/pop/pop.lua`. The `sounds/` folder must
   come with it.
2. In game, load the addon:

   ```
   //lua load pop
   ```

3. To load it automatically, add `lua load pop` to
   `Windower/scripts/init.txt`.

## Commands

Every command starts with `//pop`. Setting commands show the current value
when given no argument, and set and save it when given one. Boolean values
accept `on`/`off`, `true`/`false`, `yes`/`no`, and `1`/`0`.

### Searching

| Command | What it does |
|---|---|
| `//pop <target> [<target> ...]` | Start searching. Each target is a `0x`-prefixed hex index, a full name, or a wildcard name such as `valkurm*`. Quote names that contain spaces. With several targets, each scan is checked against them in the order given and the first match wins. |
| `//pop <target> [...] <seconds>` | Same, with the pop expected in that many seconds. The timer counts down to it with color changes and beeps. |
| `//pop stop` | Stop searching, tracking, targeting, and the timer. Zoning does the same. |
| `//pop help` | Print the command summary to the chat log. |

Examples:

```
//pop 0x00f8                               Track the mob with entity index 0x00F8
//pop "Valkurm Emperor"                    Track a mob by full name
//pop valkurm*                             Wildcards work anywhere in the name
//pop "Valkurm Emperor" 0x00f8 *hare       Several targets, checked in this order each scan
//pop 0x00f8 300                           Same, with the pop expected in 300 seconds
```

Indexes must carry the `0x` prefix. That keeps names that happen to look like
hex, such as `beef`, from being read as numbers. A bare trailing number is
always read as the expected pop time, never as a name.

When a name pattern matches more than one mob in a scan, pop lists the
candidates with their indexes and stops so you can rerun it with the exact
one.

### Behavior settings

| Command | Values | Default | What it controls |
|---|---|---|---|
| `//pop scan_delay [n]` | seconds | `5` | Time between Wide Scans while searching, and before a looped search restarts. |
| `//pop status_delay [n]` | seconds | `1` | Time between checks of a found mob: the status report and targeting while tracked, and the rescans that wait for it to die or despawn. |
| `//pop timeout [n]` | seconds | `5` | How long to wait for the server to finish sending a Wide Scan list before the search ends with an error. |
| `//pop track [on\|off]` | boolean | `on` | Wide Scan track the found mob and report its distance, HP, and claim whenever they change. When off, pop only announces the find and keeps scanning until the mob is gone. |
| `//pop target [off\|packet\|command]` | choice | `off` | How to put your cursor on the mob once it is in range. `command` sends `/target <name>`; `packet` injects the client-side lock-on packet, which selects the exact entity. Independent of `track`. |
| `//pop loop [on\|off]` | boolean | `on` | After the found mob dies or despawns, start the whole search over for the same list. When off, pop is done after one spawn. |

### Display and sound settings

| Command | Values | Default | What it controls |
|---|---|---|---|
| `//pop alert [on\|off]` | boolean | `on` | Play the chime when a target is found. |
| `//pop countdown [on\|off]` | boolean | `on` | Play the beep once per second in the last seconds before an expected pop. |
| `//pop timer [on\|off]` | boolean | `on` | Show the on-screen timer during a search. |
| `//pop timer reset` | | | Move the timer back to its default position, centered a third of the way down the screen. |

The timer can also be moved by dragging it with the mouse.

## Configuration file

Settings live in `Windower/addons/pop/data/settings.xml`, created the first
time the addon loads. Everything the commands above change is stored there,
and a few things can only be changed by editing the file. Reload the addon
after editing it by hand.

### Behavior

| Key | Type | Default | Description |
|---|---|---|---|
| `scan_delay` | number | `5` | See `//pop scan_delay`. |
| `status_delay` | number | `1` | See `//pop status_delay`. |
| `timeout` | number | `5` | See `//pop timeout`. |
| `track` | boolean | `true` | See `//pop track`. |
| `target` | string | `off` | `off`, `packet`, or `command`. See `//pop target`. |
| `loop` | boolean | `true` | See `//pop loop`. |

### Display and sound

| Key | Type | Default | Description |
|---|---|---|---|
| `alert.enabled` | boolean | `true` | Play the chime on a find. Toggled by `//pop alert`. |
| `alert.file` | string | `found.wav` | WAV file in the addon's `sounds/` folder to play on a find. Empty disables it. |
| `countdown.sound.enabled` | boolean | `true` | Play the beep in the last seconds before an expected pop. Toggled by `//pop countdown`. |
| `countdown.sound.file` | string | `countdown.wav` | WAV file in `sounds/` to play for each beep. Empty disables it. |
| `countdown.thresholds.warn` | number | `15` | Seconds remaining at which the timer turns the warn color. |
| `countdown.thresholds.alert` | number | `5` | Seconds remaining at which the timer turns the alert color and starts beeping. |
| `countdown.colors.warn` | color | yellow | Timer color inside the warn threshold. |
| `countdown.colors.alert` | color | orange | Timer color inside the alert threshold. |
| `countdown.colors.late` | color | red | Timer color at or after the expected time. |
| `found_color` | color | blue | Color of the frozen timer after a find. |
| `show_timer` | boolean | `true` | Show the on-screen timer. Toggled by `//pop timer`. |
| `timer.pos.x`, `timer.pos.y` | number | `-1`, `-1` | Screen position of the timer, saved when you drag it. A negative value means it has not been placed yet and is centered a third of the way down the screen. |
| `timer.text` | table | Consolas 16, white | Font, size, and normal color (`red`, `green`, `blue`, `alpha`) of the timer. |
| `timer.bg` | table | black, half transparent | Background box color, `alpha`, and `visible`. |
| `timer.flags` | table | `draggable`, `bold` | Text flags: `draggable`, `bold`, `italic`, `right`, `bottom`. |
| `timer.padding` | number | `4` | Padding between the text and its background box. |

A color is a block with `red`, `green`, `blue`, and `alpha`, each 0 to 255.

## How tracking ends

| Situation | With `track on` | With `track off` |
|-----------|-----------------|------------------|
| Mob dies within entity range | Detected from the mob's HP and status; logged as a death | Detected on the next scan when the mob is missing |
| Mob dies or despawns far away | Detected when the client drops the Wide Scan track | Detected on the next scan when the mob is missing |
| You zone | Everything stops | Everything stops |
| `//pop stop` | Everything stops | Everything stops |

## Notes

- Everything pop does with Wide Scan goes through the same requests the game
  itself makes. The `packet` targeting mode is the one exception: it feeds the
  client a lock-on packet locally and sends nothing to the server.
- The chime and beep are small generated WAVs. Replace the files in `sounds/`,
  or drop in others and point `alert.file` or `countdown.sound.file` at them,
  if you prefer different noises.
