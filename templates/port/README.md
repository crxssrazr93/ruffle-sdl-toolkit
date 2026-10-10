## Installation

This is the README that ships with the port (PortMaster shows it as the port's page, and the release script renames it to MYPORT.md). Replace every MYGAME and MYPORT. Keep it short and plain.

Buy the game on [MYSTORE](https://example.com/store/page) and copy everything from its install folder into `ports/MYPORT/gamedata/` (you should see `MYGAME.swf` and the folders `data` and `levels`, edit this to match). The first launch patches the files, which takes a few minutes. Only the supported release is accepted: the setup checks every file against a list of checksums and stops with a message when a file is missing or different. If files are missing or damaged, copy the game files again: the next launch patches them again.

## Controls

Buttons are named as the game's prompts show them. They work by position, as SDL lays them out: A is the bottom button (labelled B on Anbernic devices). On Knulli you can swap them per game: long press X on the game in the ports list and change its A/B layout setting. Edit the table to your `MYPORT.gptk`.

| Button | Action |
|--|--|
| D pad / Left stick | Move |
| A / B / X / Y | Jump / Attack / Special / Extra |
| Start | Pause |
| L1 / L2 | Music / sound volume (steps: 100%, 50%, off) |
| Select + Start | Quit |

Optional rows, only when you enable them in `MYPORT.gptk` and the game has a visible cursor:

| Button | Action |
|--|--|
| Right stick | Move the mouse pointer |
| R1 / R2 | Left / right click |

## Notes

* On 1 GB devices turn on zram (or swap) in your firmware's settings, so the game does not run out of memory. Flash games keep a lot of data in memory, and a port that looks light still used about 600 MB on a handheld.
* Performance depends on the game. Heavy 3D (Stage3D) or very large levels can run at 15 to 20 fps on the weakest devices. Settings that help: `QUALITY="low"` (the default), `FRAME_RATE="30"`, and a smaller `RENDER_SIZE` such as `"640x480"` in `ports/MYPORT/MYPORT.cfg`.
* If the game is split into several SWF files, entering another area shows a short black screen while Ruffle restarts to free memory. This is on purpose.
* Online features, store achievements and cloud saves are not available. Progress is saved locally in `ports/MYPORT/saves/`.
* Settings (quality, screen fit, frame rate, render size, memory tuning) are in `ports/MYPORT/MYPORT.cfg`. Delete the line of a setting to get its default back, or copy the file again from the zip.
* Test builds write a detailed `log.txt` (and the previous run as `log.prev.txt`). If you want a short log, set `VERBOSE_LOGS=0` in the cfg.

## Reporting problems

Please send `ports/MYPORT/log.txt` and `ports/MYPORT/patchlog.txt` (the setup's log) from right after the problem, and say which device and firmware you use.

## Thanks

The game's developer for the game, the [Ruffle](https://ruffle.rs) team, Knifethrower for the SDL front end and memory savings, and everyone who tested.

Source and build details: https://example.com/your-port-repo
