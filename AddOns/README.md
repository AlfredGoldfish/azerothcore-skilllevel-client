# SkillLevelUI — client addon (WotLK 3.3.5a)

Shows your **custom skill levels** and **scaled bonus damage** in-game, so you can
see the skill-leveling system working instead of the static "Rank 1" tooltip.
The server pushes the data; this addon displays it. **Both you and your brother
install it** (it's just a folder — no client patch, no rebuild).

## What it does
- **Spell tooltips:** hovering a tracked shot (Steady Shot, Arcane Shot, Raptor
  Strike, …) adds `Skill Level N`, `Scaled bonus: +X damage`, and an **XP progress
  bar** (`====----  61 / 400 xp`) so you can watch a skill fill toward its next level.
- **`/skillui` panel:** a movable window listing every tracked skill's level, bonus, and XP.
- **Talent window (N) unlocked at level 1:** re-enables the talent frame that WotLK
  normally gates to level 10 (the trees show; our custom talents are still `.talent`).
- Updates **live** on level-up, and on login (auto-sync a few seconds after you enter world).

## Install
1. Copy the **`SkillLevelUI`** folder into your client's addons folder:
   `<your WoW 3.3.5a>\Interface\AddOns\SkillLevelUI\`
   (so you have `Interface\AddOns\SkillLevelUI\SkillLevelUI.toc` and `...\SkillLevelUI.lua`).
2. At the character-select screen, click **AddOns** (bottom-left) and make sure
   *Skill Level UI* is enabled and "Load out of date AddOns" is checked.
3. Log in. You'll see a "SkillLevelUI loaded" line in chat.

## Using it
- Hover any of your 13 damage shots → the tooltip shows its skill level + bonus.
- Type **`/skillui`** to toggle the panel; drag it anywhere.
- If the panel/tooltips look empty (e.g. right after a `/reload`), type **`.skillsync`**
  in chat to make the server re-send your data.

## Notes
- The addon's skill list must match the server's. If skills are ever added/renamed
  on the server (in `lua_scripts/skilllevel_core.lua`), update `SKILL_NAME`/`ORDER`
  in `SkillLevelUI.lua` to match.
- Requires the realm's server-side scripts (already live on v2). No effect on a
  normal realm.
