# Skill Issue Launcher & Client Add-ons

Client-side files for the **"It's a Skill issue Mikey"** private server (AzerothCore 3.3.5a),
plus a tiny **update-and-play launcher**. This repo is intentionally small — it holds only
the custom UI add-ons and the launcher, **not** the multi-GB game client.

## What's here
- `AddOns/` — the custom UI add-ons (Bagnon + SkillLevelUI, SkillTrainerUI, ServerBags, RareRadar, QuickBags, ErrorSpy).
- `SkillIssueLauncher.ps1` — the launcher (Windows PowerShell + WinForms, zero dependencies).
- `Play.bat` — double-click this to run the launcher.

## First-time setup
You **don't need to source a game client yourself** — the launcher can download a
complete, correct one for you.

1. Make sure **Tailscale** is installed and connected (see the separate connect guide).
2. Put this launcher folder anywhere handy and double-click **`Play.bat`**.
3. On first run it asks about the game:
   - **Download & install the game for me (~16.5 GB)** — grabs a complete ChromieCraft
     3.3.5a client (build 12340, all runtime DLLs included), so there's nothing to copy
     from Josh and no missing-`.dll` errors. Optional **HD graphics patch** checkbox
     (+3.2 GB). The download **resumes** if it's interrupted or you close the launcher.
   - **I already have WoW 3.3.5a** — pick your folder (the one with `Wow.exe`) instead.

   It remembers your choice; after that it just updates add-ons and launches.

> Already have a client but want the sharper textures later? Open the launcher and click
> **Install HD graphics patch** on the main window.

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
