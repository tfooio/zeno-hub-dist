# Zeno Hub

Anime Adventures script hub. Run this in your executor:

```lua
loadstring(game:HttpGet("https://raw.githubusercontent.com/tfooio/zeno-hub-dist/main/loader.lua"))()
```

To start it by itself, save that same line as a file in your executor's `autoexec` folder.

- Right Ctrl hides or shows the window.
- Needs an executor with `loadstring`, `game:HttpGet`, `getgenv`, `gethui`, `readfile`, `writefile`, `appendfile`, `isfile`, `isfolder`, `makefolder`, `listfiles`, `delfile`. `queue_on_teleport` re-runs the hub after each teleport. Recording macros also needs `hookmetamethod`, `newcclosure`, `checkcaller`, `getnamecallmethod`.
- Your settings are saved per Roblox account in `workspace/Zeno Hub/Config/<name>/`; macros in `Zeno Hub/Macro/AnimeAdventures/`; logs in `Zeno Hub/Logs/`.
- Updates reach you the next time you run it (GitHub can take about 5 minutes to serve a new push).
- Using scripts in Roblox can get an account banned. Use at your own risk.

Version: 61dc617 (2026-10-26)
