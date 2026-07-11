# Skill Issue Launcher & Client Add-ons

Client-side files for the **"It's a Skill issue Mikey"** private server (AzerothCore 3.3.5a),
plus a tiny **update-and-play launcher**. This repo is intentionally small — it holds only
the custom UI add-ons and the launcher, **not** the multi-GB game client.

## What's here
- `AddOns/` — the custom UI add-ons (Bagnon + SkillLevelUI, SkillTrainerUI, ServerBags, RareRadar, QuickBags, ErrorSpy).
- `SkillIssueLauncher.ps1` — the launcher (Windows PowerShell + WinForms, zero dependencies).
- `Play.bat` — double-click this to run the launcher.

## First-time setup
1. Get the **WoW 3.3.5a game folder** from Josh (one-time; e.g. sent over Tailscale). This is the big part.
2. Make sure **Tailscale** is installed and connected (see the separate connect guide).
3. Put this launcher folder anywhere handy and double-click **`Play.bat`**.
4. On first run it asks for your WoW folder (the one with `Wow.exe`) — pick it once; it remembers.

## Every time after that
Just double-click **`Play.bat`**. It will:
1. Pull the latest add-ons from this repo and install them into `Interface\AddOns\`.
2. Point the game at the server (`set realmlist 100.109.250.55`).
3. Check the server is reachable, then let you hit **PLAY**.

Log in with your account and pick the **It's a Skill issue Mikey** realm.

## For Josh: publishing add-on changes
Edit add-ons in the main server repo under `client-addon/`, then run
`scripts\publish-client.ps1` there. It mirrors your changes into this repo and pushes them —
Josh's and Mike's launchers pick them up the next time they open.
