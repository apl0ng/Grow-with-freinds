# FRIENDSLOP.md — what makes friendslop good, and how Grow With Friends gets it

Owner: lead. Design rationale for milestone M10 (PLAN.md). Interfaces live in CONTRACTS.md, tone in STYLE.md.

## 1. What the genre is

"Friendslop" is the 2024–2026 wave of cheap, simple co-op games (Lethal Company, Content Warning, R.E.P.O.,
Peak, Chained Together, Supermarket Together) whose fun comes from the *players* more than the game. The Peak
studio put it bluntly: the genre "assumes that you and your friends will make up the difference in comedy and
interaction in what the game is lacking" (GamesRadar, 2025). The recurring machinery is the same everywhere:
a simple shared goal, proximity voice chat, physics you can do to each other, limited information, and a light
threat used for comedy rather than difficulty (Wikipedia; Creative Bloq; gamedesignlibrary.com on Lethal
Company). Lethal Company's own loop is the closest cousin of ours: blue-collar workers, a Company, a quota that
rises until you inevitably fail, and "failure feels like firing, not death".

Sources: GamesRadar "We proudly wear the friendslop badge" (Peak studio); Wikipedia "Friendslop"; Creative Bloq
"What is friendslop"; gamedesignlibrary.com "Proximity chat changes the game"; KnowYourMeme "Friendslop";
naavik.co "Friendslop: disrupting the live-ops status quo".

## 2. The seven ingredients, and our version of each

1. **Voices in space.** You hear friends only when they are near; a voice trailing off across the room, or
   cutting out, is the whole show. → `Voice` autoload: proximity voice chat, push-to-talk by default, 3D at the
   speaker's head, ~14 m range. Workers in the back room hear each other and the floor faintly; the floor cannot
   hear them. Speaking indicator in the WORKERS list and on name labels.
2. **Physics you can do to each other.** The funniest object on screen is a friend. → Throw whatever you hold
   (RMB): product bundles fly, a bundle to the head staggers a worker and knocks their item loose, a bundle
   thrown *into the chute* deposits. Shove (F): a nudge from the front, a stumble and a dropped item from behind.
   Workers collide with each other, so a gate is a choke point.
3. **A shared enemy that punishes slowly and publicly.** Not a jump scare: a presence you have to manage
   together. → **Inspections**: the Boss leaves the cage with a clipboard and walks the floor for a while.
   Anyone in his sight carrying product is "skimming", anyone standing still is "loitering": a write-up, a fine,
   the product confiscated. You can see him coming, crouch behind a tray, or shout across the room.
4. **Failure is a story, not a loss.** Consequences that make a clip, then put you back in play. → Three
   write-ups send a worker to the **back room** for 30 s: input off, dark overlay, spectating teammates through
   a cycling camera, still talking (to other back-room workers). Shifts stay short (5 min) and a missed payment
   is a restart, never a lecture.
5. **Divided attention and information gaps.** Coordination has to fall apart in funny ways. → **Power cut**:
   lights die, growth pauses, someone has to find the fuse box by ear while the Boss says "Not my problem."
   **Audit**: the number goes up mid-shift. A **rat** (stretch) eats a growing plant unless someone chases it off.
6. **A ledger for banter.** The end screen is where the arguments start. → **Shift report** per worker:
   deposited, planted, watered, harvested, write-ups, throws, hits. Verdicts: "Least useful: …", "He noticed:
   …", "Worst behaved: …". Flat copy, no trophies.
7. **Low floor, no lectures.** Anyone can play in a minute, with or without a mic. → Ping (middle click) drops a
   marker with your name; chat (T) for mic-less friends; every new verb is one key.

## 3. Tone guard

Friendslop is loud; this game is grim. The chaos comes from the players; the game never cheers. Rules that hold
under M10: no "!" and no praise in any new copy; the Boss's lines during inspections are flat ("Skimming, Bob.",
"That's mine now."); the shift report reads like a performance review, not a scoreboard; the back room is a
dark screen and a countdown, not a death animation; no confetti, no ragdolls, no blood; the rat is thin and sad.
Sounds are dull and low (STYLE.md §7): footsteps on concrete, keys jingling on a walking Boss, a breaker
thunk, a door that slams.

## 4. M10 feature set (who builds what: PLAN.md team table)

| Feature | Autoload / files | Owner |
|---|---|---|
| Proximity voice chat, push-to-talk, back-room channel, speaking indicators | `scripts/core/voice.gd` | voice |
| Throw (arc, hits, chute shots), shove, worker collision, footsteps, stagger | player / interactor / items | physics |
| Events: inspection (Boss walks, clipboard, sight checks), power cut + fuse box, audit, rat (stretch) | `scripts/core/events.gd`, NPC, room, fuse box | events |
| Write-ups, fines, back room state, per-worker stats (server-authoritative) | `scripts/core/game_state.gd` | lead |
| HUD (speaking marks, write-up marks, event banner), back-room overlay + spectator camera, shift report, ping + chat, Boss lines | ui / `scripts/core/comms.gd` / `story.gd` | ui |
| New sounds + loops (steps, keys, breaker, hum, door), event alarms | `scripts/art/sfx.gd` | audio |
| Models: fuse box, clipboard, rat, back-room door; the Blender pipeline on Windows | `tools/blender/**`, `art/models/**` | modeling |

## 5. What we deliberately do not do

- No ragdolls or gore: a stagger and a dropped item are the whole joke.
- No screamers: the threat is a man with a clipboard walking slowly.
- No unlocks or cosmetics store: nothing here is a reward.
- No open-mic by default (push-to-talk), no voice through walls of the cage.
- No griefing without a counter: a shove costs a cooldown, a throw costs the item, write-ups cost the team money.

## 6. What a good session looks like (playtest checklist)

- Two workers on a call, one drops the mic-less friend a ping and a chat line, and they still coordinate.
- The lights go out; someone says "who has the fuse box", footsteps in the dark, a thunk, fluoros flicker on.
- "He's out. He's OUT." Everyone hides product; one worker gets caught skimming; the Boss says the name.
- Somebody lands a bundle in the chute from the gate and nobody says "nice".
- A worker in the back room narrates the others' mistakes to the other back-room worker.
- The shift report names the least useful worker and the argument starts.

## 7. M12: things that go wrong on purpose
The loop (buy, plant, water, harvest, sell) is only fun while something keeps breaking it. M10 added the Boss, the
power cut, the audit and the rat. M12 adds three kinds of trouble, each one a decision for the group rather than a
damage number:
- **Strains with a temper.** Three new seeds pay better and grow stranger. Each strain has a `mutation_chance`: a ready
  plant may twitch for six seconds and then uproot itself. The pay-off is real, so somebody will plant Night Shift
  anyway. That is the point.
- **The hostile plant.** It leaves the plot it came from, eats the nearest growing plot, and bites whoever comes close
  (a stagger, the item knocked out of your hands). Nothing you own stops it except fire, so the group has to choose
  between saving the crops and keeping its distance. It never kills anyone: nobody is happy, nobody is dead.
- **Break glass.** A red cabinet on the wall holds one flamethrower. Breaking the glass costs a deposit, and breaking
  it when nothing is on the floor is a write-up ("misuse of emergency equipment"). The flamethrower also burns crops
  and workers, and that is a write-up too ("arson"). Fuel runs out in eight seconds; the cabinet restocks in ninety.
- **Interruptions.** Head count (everyone to the line in fifteen seconds or a write-up), water main off (the well has
  no pressure, plants dry), supply shortage (the strain you planted most is out of stock). None of them hurt; all of
  them cost time you do not have.
Tone guard still applies: the plant does not roar, the flamethrower does not whoosh heroically, the Boss does not
thank you for putting the fire out. He notes the deposit.
