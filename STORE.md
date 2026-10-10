# Grow With Friends: store page

Material for a store page (RELEASE.md R6). Where it goes and the price are the user's decision; itch.io is the
obvious first stop. The screenshots come from `tools/tests/store_shots_body.gd` (eight moments at 1920x1080).

## Pitch (one line)
You owe the Boss. One to four of you work it off: grow it, deposit it, pay him, and do it again for a bigger number.

## Short description
Co-op first-person for one to four friends. You owe the Boss. Buy seeds at his window, grow them, deposit the
product and make the payment before the shift ends. The lights go out. The tank leaks. A plant gets up and walks.
Four to six shifts, then the debt is paid or you start over.

## Long description
The Boss has a factory, a barred window and a number. You and up to three friends have a debt. Every shift you buy
seeds from him on credit, plant them in his trays, carry water from his tank, harvest what comes up and push it down
his chute. When the deposits cover the payment, the shift is over and the number goes up. A run is four to six
shifts, depending on how many of you showed up. The last one is the final notice. Pay it and the debt is cleared.
He will find another.

Things go wrong about every two minutes, and each one warns you first. The Boss walks the floor and writes up
anyone holding product or standing still. The power goes and somebody has to find the breaker. The tank springs a
leak. A car slows down outside and everyone gets on the floor. A rat gets into a tray. The phone rings and nobody
wants to answer it. The sprinklers come on and the floor is wet for a while. Sometimes a ripe plant gets up and
leaves the tray, and the only thing that stops it is in the red cabinet by the fuse box. One strain puffs spores
when you disturb it. You will cough.

Nobody here is happy. The work is the same every shift and the crew talks the whole time.

- One to four players on the same network, or online when the host forwards a port. One hosts, the others join by
  IP or from the list of floors nearby.
- Proximity voice chat, two walkie-talkies that carry your voice anywhere on the floor, text chat, pings, and four
  gestures (pointing, a tired wave, a shrug, sitting down).
- Seven strains, drying racks for a better price, favors from the Boss on your tab, an optional job every shift.
- A run is four to six shifts of five minutes. Every run has a four-character code: give it to friends and they
  get the same shifts. A new code every week.
- Your record stays on your PC and issues hats. Nothing is bought.

## Tags
co-op, multiplayer, online co-op, LAN, first-person, farming, management, comedy, dark humor, cartoon, low-poly,
voice chat, short sessions, 1-4 players

## Content
Gunfire (a drive-by; nobody bleeds), an implied illegal grow, debt, a flamethrower kept behind glass.

## System requirements
| | Minimum | Known or guessed |
|---|---|---|
| OS | Windows 10 or 11, 64-bit | Known: the export is Windows x86_64 only. Windows 10: a guess (tested on Windows 11 only). |
| Graphics | A GPU with Vulkan 1.0 or Direct3D 12 | Known: the game uses Godot 4.7's Forward+ renderer (Vulkan first, Direct3D 12 as Godot's fallback). Godot's own guide puts Vulkan at NVIDIA GeForce 600, AMD Radeon HD 7000 or Intel HD Graphics 500 and newer: not tested here. |
| Processor | A dual-core x86-64 CPU | Guess. The host runs the whole floor; give the host the faster PC. |
| Memory | 4 GB RAM | Guess. |
| Storage | 500 MB | Guess until the lead fills in the zip and exe size after the export. |
| Network | Internet or a local network for multiplayer | Known: the host needs UDP 7777 reachable (forwarded on the router for internet play); the list of floors nearby uses UDP 7778 on the local network. |
| Sound | A microphone for voice chat (optional) | Known: push to talk on V by default. |

Developed and tested on Windows 11 with an NVIDIA RTX 4070 SUPER at 1920x1080. Godot falls back to its OpenGL
compatibility renderer on a GPU without Vulkan or Direct3D 12; the game has never been tested there and may look
wrong.
