# Loot Highlight (WoW Forever)

Makes herbs, ore, chests, quest objects and lootable corpses easy to notice.

## What it does

- Twinkling glints drift over the nearest thing you can gather or loot, all around you (not only in front).
- Knows what the thing is (herb, ore vein, chest, corpse, chair...) and only alerts for what you want. Herbs, ore and skinning are on "Auto" by default: shown only when your character has that profession. Chairs, doors and mailboxes are off by default.
- Bright glints when you are close enough to use it, dimmed glints when you need to walk closer, and grey glints with the skill you need (for example "need Mining 65, you have 40") when your skill is too low.
- The banner and ping only come once per node: going back to the same vein between loots stays quiet.
- Every type has its own color (herbs green, ore copper, chests gold...) and you can pick any color for each one.
- Optional banner at the top of the screen with the object's name, and a short ping when something new comes into range.
- Can set the game's own object outline (Outline Mode), so you get outlines and glints together.
- Can keep the game's quest item sparkle on (the game only shows it while outlines are off).

Safe with spells: soft targeting can make a spell cast without a target land on a player or NPC standing next to you. Loot Highlight switches it off while it points at a living player or NPC and during combat, and back on after a few steps. Corpses don't keep an empty health bar, and nothing is highlighted during a fight.

If another sparkle addon (Sparkles, Lueur, Forever Loot Sparkles 1.x or its Herbs & Ores add-on) is also on, you get a chat note: keep only one, or they undo each other's settings.

The glints can only react to the nearest thing within the game's soft-target range (about 15 yards at most); addons are not told about objects further away.

## Install

1. Close the game completely.
2. Copy the `LootHighlight` folder into `World of Warcraft\_forever_\Interface\AddOns\`
   (the result should be `...\AddOns\LootHighlight\LootHighlight.toc`).
3. Start the game. On the character screen, open AddOns and check that Loot Highlight is enabled.

## Settings

Esc > Options > AddOns > Loot Highlight, or type `/lh`.

| Setting | What it does |
| --- | --- |
| Herbs / Ore veins / Skinnable corpses | Auto (only with the profession), On or Off |
| Chests and quest objects, Corpses with loot | On or Off |
| Chairs, doors, mailboxes | On or Off (Off by default) |
| Addon on | Off also gives back your own interact settings |
| Range asked for | The game stops at about 15 yards whatever is set here |
| Ignore nearest thing / Clear ignore list | Stop alerts for one specific thing by name |
| Color square next to each type | Opens the game's color picker; that color is used for the glints and the banner of that type |
| Reset colors | Puts every type back to its starting color |
| Glints on the object, Glint style, Number, Size, Height | How the glints look |
| Game's interact icon | Show or hide the game's own icon above the object (pickaxe, flower, hand) |
| Object outline | Keep (your graphics setting), High, Good or Off |
| Quest item sparkles | The game's sparkle on quest items (only shows with outline Off; turning it off needs a game restart) |
| Banner, Ping sound | Extra alerts |

Shortcuts: `/lh on`, `/lh off`, `/lh ignore`, `/lh test`, `/lh height -120` and `/lh size 140` (tune the glint cloud while standing at a node), `/lh what` (shows what the game says the nearest thing is; handy for bug reports).

Don't run it together with other addons that change soft targeting (Forever Loot Sparkles, Lueur). They fight over the same game settings.

## Tip

Bind a key to **Interact With Target** (Options > Keybindings > Targeting). Then you can loot whatever the glints are on by pressing that key, without hunting for it with the mouse.
