# Bag addon (WotLK 3.3.5a client)

The server's bag UI is **Bagnon** — a well-designed, single-window inventory
replacement (search, sort, bag-slot bar, item coloring, one-window bank/keys).
It is the base we build the server's bag features on.

## What's here
- **`Bagnon/`, `Bagnon_Config/`, `Bagnon_Forever/`, `Bagnon_GuildBank/`,
  `Bagnon_Tooltips/`** — Bagnon 2.13.3 (Tuller), 3.3.5 backport.
  Source: https://github.com/RichSteini/Bagnon-3.3.5 (Interface 30300).
  Libraries (Ace3, LibItemSearch, LibStub, LibDataBroker) are bundled inside
  `Bagnon/libs/` — no separate installs needed.
- **`Bagnon_VoidStorage/` is intentionally NOT included** — Void Storage is a
  Cataclysm+ feature; its module calls APIs that don't exist in 3.3.5a.
- **`ServerBags/`** — small **Bagnon companion** that adds the two server-specific
  features Bagnon lacks (Bagnon already covers unified window, search, bag-slot bar,
  quality borders, counts, sort):
  1. **Sell-all by quality** — a panel of one-click vendor buttons
     (Gray/White/Green/Blue/Purple) that appears next to the merchant window.
     Blue/Purple ask to confirm. Locked items are skipped.
  2. **Item lock** — **Alt+click** any item to protect it from Sell-all; a padlock
     overlay + a tooltip line mark locked items.
  Leaves Bagnon stock (hooks it non-destructively); degrades gracefully if Bagnon
  is absent. Migrates existing locks from `QuickBagsDB` on first load.
- **`QuickBags/`** — the previous all-in-one custom bag addon, kept for reference /
  rollback. Superseded by Bagnon + ServerBags; disabled in the live client.

## Install (per player)
Copy the five `Bagnon*` folders into `<WoW 3.3.5a>\Interface\AddOns\`.
At character select → **AddOns**, enable Bagnon and check "Load out of date AddOns".

## QuickBags ↔ Bagnon (don't run both)
Both hijack the bag key (`ToggleBackpack`/`OpenAllBags`), so only one can be the
active bag window. In the live client, `QuickBags` is disabled by renaming its
folder to `QuickBags.off` (WoW won't load a folder whose name doesn't match its
`.toc`). To switch back, rename it to `QuickBags` and disable the `Bagnon*` folders.
