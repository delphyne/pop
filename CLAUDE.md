# pop

A Windower 4 addon for Final Fantasy XI. Single file, `pop.lua`, plus the
`sounds/` folder. See README.md for what it does and how to use it.

## Installation on this machine

Windower runs under the Lumoria Flatpak's Wine prefix. Its addons folder is:

```
/home/deck/.var/app/net.windower.Lumoria/data/prefixes/prefix-1/pfx/drive_c/Windower4/addons
```

Addons there are installed as symlinks back to their git checkouts, so edits
in the repo take effect on the next reload. Install this one the same way:

```
ln -s /home/deck/scm/github/delphyne/pop \
  /home/deck/.var/app/net.windower.Lumoria/data/prefixes/prefix-1/pfx/drive_c/Windower4/addons/pop
```

Then in game:

```
//lua load pop
```

After editing `pop.lua`, reload with `//lua reload pop`.

## Notes

- `data/` holds runtime settings written by the config lib and is gitignored.
- Commit messages are prefixed with `[pop]`.
