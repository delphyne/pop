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

Settings are saved to `Windower/addons/pop/data/settings.xml` the first time
you change one.

## Usage

```
//pop 0x00f8                               Track the mob with entity index 0x00F8
//pop "Valkurm Emperor"                    Track a mob by full name (quote names with spaces)
//pop valkurm*                             Wildcards work anywhere in the name
//pop "Valkurm Emperor" 0x00f8 *hare       Several targets, checked in this order each scan
//pop stop                                 Stop searching, tracking, and targeting
//pop help                                 Show the command summary in game
```

Indexes must carry the `0x` prefix. That keeps names that happen to look like
hex, such as `beef`, from being read as numbers.

When a name pattern matches more than one mob in a scan, pop lists the
candidates with their indexes and stops so you can rerun it with the exact
one.

Any option in the table below can be shown by typing its name alone, for
example `//pop delay`, or changed by adding a value, `//pop delay 3`.

## Options

| Option    | Command                               | Type    | Default     | Description |
|-----------|---------------------------------------|---------|-------------|-------------|
| `delay`   | `//pop delay <seconds>`               | number  | `1`         | Seconds between scans while searching, and between status checks once a mob is found. |
| `timeout` | `//pop timeout <seconds>`             | number  | `5`         | Seconds to wait for the server to finish sending a Wide Scan list. If it does not arrive, the search ends with an error. |
| `alert`   | `//pop alert on\|off`                 | boolean | `on`        | Play a sound when a target is found. |
| `sound`   | edit `data/settings.xml`              | string  | `found.wav` | File in the addon's `sounds/` folder to play. Must be a WAV. Empty disables the sound. |
| `track`   | `//pop track on\|off`                 | boolean | `on`        | Wide Scan track the found mob and report its distance, HP, and claim whenever they change. When off, pop only announces the find and keeps scanning until the mob is gone. |
| `target`  | `//pop target off\|packet\|command`   | choice  | `off`       | How to put your cursor on the mob once it is in range. `command` sends `/target <name>`; `packet` injects the client-side lock-on packet, which selects the exact entity. Independent of `track`. |
| `loop`    | `//pop loop on\|off`                  | boolean | `on`        | After the found mob dies or despawns, start the whole search over for the same list. When off, pop is done after one spawn. |

Boolean options also accept `true`/`false`, `yes`/`no`, and `1`/`0`.

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
- The chime is a small generated WAV. Replace `sounds/found.wav`, or drop in
  another file and point the `sound` setting at it, if you prefer a different
  noise.
