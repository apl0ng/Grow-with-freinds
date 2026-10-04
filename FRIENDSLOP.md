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

## 8. M14 brainstorm: a bigger floor, a van, and more things going wrong (2026-10-02)
Asked for by the user: more ways to break the loop, a better loop, strains that mean something, a bigger place, a lobby
with a van, more "what the hell" moments, footsteps that do not suck. Each idea is marked **now** (being built in M14),
**next** (good, not started) or **parked** (does not fit yet).

### 8.1 The start: a lobby and a van (now)
- Workers spawn in a back alley at night: a street lamp, bins, the van with its rear doors open. This is the place to
  shove each other, throw a can at the lamp and wait for the late one.
- The shift starts when every worker in the session stands in the back of the van. Doors close on a short count, the
  screen goes black, and everyone is on the loading dock of the floor. The drive is never shown.
- Between shifts the report is read on the floor, then everybody is back in the alley. The host can still press Enter
  to leave without the one who will not get in.

### 8.2 A bigger floor (now)
The single room is 20 by 15 metres with six trays and a lot of empty concrete. More space only helps if it puts
distance between the steps of the loop, so people split up, lose sight of each other and have to shout.
- **Grow hall** to the east through two doorways: four more trays (ten in all) and the drying racks. The plant now has
  two pens to walk between.
- **Loading dock** to the south: where the van drops you, crates for cover, the roll-up door the outside comes through.
- The old room keeps the supply window, the tank, the chute, the fuse box and the cabinet. Water, seeds, trays and the
  chute are now in different rooms.
- next: a roof hatch and a basement stash; parked: a second floor (too much level for the head count).

### 8.3 A loop with one more decision (now)
- **Drying racks.** A harvested bundle sells as it is, or hangs on a rack for forty-five seconds (twenty until M15) and sells cured for forty
  per cent more. A hanging bundle can be taken, shot, eaten or burnt. Sell wet now or leave it and hope.
- next: the scale lies some shifts (the chute pays ten per cent less until someone hits it); a hand truck that carries
  three bundles and steers badly; watering from a hose that reaches one room only.

### 8.4 Strains that play differently (now: refine the six, add none, remove none)
Today the six strains differ in price, time and mutation chance only. Each gets one trait, visible on its card:
- **Budget Bud**: nothing. The control group.
- **Purple Haze**: thirsty. Dries sixty per cent faster.
- **Golden Kush**: counted. Lose one to the plant or to fire and the Boss fines the floor.
- **Night Shift**: grows in the dark. During a power cut it grows at double speed while everything else stops. Still
  one in three walks.
- **Creeper**: spreads. One harvest in three leaves a seedling behind in the same tray.
- **Floor Brick**: heavy. Whoever carries the bundle walks slower and cannot sprint.
- next: Skunk (pays well, the smell brings the Boss out more often); Glass (a thrown bundle shatters);
  parked: removing Budget Bud (new players need one plain strain).

### 8.5 What-the-hell moments
Rule: each one takes the floor's attention for under a minute, has a physical answer, and costs time, not lives.
- have: inspection, power cut, audit, rat, head count, water main off, supply shortage, the hostile plant.
- **now: the tank springs a leak.** A jet from the tank and a spreading puddle. Hold E on the hole to patch it. Not
  patched in time: the tank is empty for a minute. Sprint through the puddle and you slip.
- **now: a drive-by.** Tyres outside, two and a half seconds of warning, then six seconds of gunfire through the dock
  door and the windows. Standing in a lane: knocked down, item dropped. Crouched or behind a crate: fine. Trays in a
  lane lose progress, a lamp goes out. Nobody dies. The Boss bills the floor for the glass.
- next: a raid (sirens; every bundle in sight after twenty seconds is taken, so hide it or sell it); sprinklers (every
  tray watered to the top, the floor slippery, the power out); the Boss's nephew (walks around, picks things up, drops
  them elsewhere); a wrong delivery (a pallet of crates lands on the dock and blocks the door until moved); a
  collection (a man at the door wants a payment now: put cash in the tray or he takes a bundle).
- parked: anything that removes a player from the game for longer than the back room does.

### 8.6 Footsteps (now)
The complaint is fair: at walking speed the game plays six steps a second, almost twelve when sprinting, all the same
sample. Fix: one step per human stride (about three a second), three variants, a heavier heel and less hiss, quieter
when crouched, a landing thud after a jump.

## 9. M15: why you would play it again (2026-10-02)
The user: "refine gameplay, I want to be able to have good replayability." A session is replayable when the same
people can start again and not know how it will go. Four things do that here; each is marked **now** (M15) or **next**.

### 9.1 No two shifts alike (now)
- **Shift conditions.** From the second shift on, the board in the alley shows what is different today, before anyone
  gets in the van: dry air, a twitchy batch, a buyer for one strain, clearance at the window, inspection week, bad
  wiring, a short clock, overtime, a slick floor, thin walls. One per shift, two from shift five. The plan is made in
  the alley and the plan is different every time.
- **A market.** Every strain's deposit value moves up to 15% either way each shift. The best strain yesterday
  is not the best strain today, and the supply card says so.
- **More that can go wrong.** A raid (hide or sell every bundle before they look in), the sprinklers (everything
  watered, the whole floor slippery), the collector (pay him at the dock or he takes the dearest thing). Twelve event
  kinds now, and they come faster each shift.

### 9.2 A run that builds (now)
- Strains open up by shift: the plain ones first, Golden Kush at two, Night Shift at three, Floor Brick at four. A run
  has a beginning that is simple and a late game that is not.
- The payment due is retuned for ten trays and cured bundles, from a model of the loop rather than by feel: an average
  player alone makes the first shift and misses the second, four who split up make the third, nobody makes the sixth
  without favors and the racks.

### 9.3 Something to chase (now)
- **Contracts.** One optional job a shift from the Boss: three cured bundles, no write-ups, burn the plant, nobody
  shot. Cash on the spot when it is met.
- **A record.** Each player's own file: shifts worked, best shift reached, total deposited, plants burnt, times
  bitten. The alley board shows it; a flat job title follows the best shift and sits next to your name.

### 9.4 The room between runs (now)
- The alley has a ball, a hoop with a counter, and the board with the last shift and today's briefing.

### 9.5 Next
- A second layout (the same rooms joined differently, picked per run); crate cover shuffled per run; a weekly seed so
  friends can compare the same run; hats bought with career cash; a "final notice" shift with a boss-level event.

## 10. M16: the floor moves, issued kit (2026-10-02)
M15 made the card different every shift. Two things were still the same every run: the room, and the worker.

### 10.1 The floor moves (now)
- **Cover that moves.** The crates and pallets on the dock, in the main room and in the hall stand differently each
  run (four arrangements). The spot that hid a bundle from the raid last run is in the open this run; the crate that
  stopped the rounds is somewhere else.
- **A run code.** Every run has a four-character code on the alley board. The same code gives the same card: the
  same conditions, market, jobs, order of events and cover. Type a friend's code into the host panel and play what
  they played. "This week" fills in a code that is the same for everyone that week.

### 10.2 Issued kit (now)
- Nothing is bought and nothing is a reward. The record issues it: a hairnet after the first shift, a paper cap
  after ten, a hard hat for reaching shift three, a traffic cone for three trips to the back room, a bucket for
  being bitten five times, a welding mask for five plants burnt. It is in the locker in the alley and everyone on
  the floor sees it. The worst record has the most hats.

### 10.3 Small things (now)
- Three more jobs (one bundle each of three strains; lose no plant; a raid that takes nothing), a cap on how many
  plants a condition can make walk, an uprooting sound, empty flamethrowers cleared away, and a tool that writes
  every new sound to a file so it can be heard before it is trusted.

### 10.4 Next
- A second way the rooms join; a "final notice" shift with its own event; a hand truck; the scale that lies.

## 11. M17: a run has an end (2026-10-02)
After M16 a run could be different every time and still had no shape: it went on until a payment was missed, so
every session ended in a failure. A run needs a last shift.

### 11.1 The final notice (now)
- A run has a last shift: the fourth for one worker, the fifth for two, the sixth for three or four (what the
  economy model has a careful crew of that size reach). It is posted as the final notice. It always has two
  conditions, and at half time the Boss looks at the number: under 40% deposited and the payment rises by a tenth.
- Pay it and the debt is cleared: "PAID IN FULL. He will find another." The record counts debts cleared and issues
  one more hat for the first. Nobody is happy about it. The next run is a new run.

### 11.2 A hand truck (now)
- One stands on the dock. It is heavy to carry, it takes four bundles, and whoever holds it at the chute deposits
  all of them. The racks are in the hall and the chute is in the main room: somebody is going to make that walk
  with four cured bundles while the raid sirens start.

### 11.3 Two small things that go wrong (now)
- **The scale is off.** Every deposit pays 15% less until somebody hits the chute.
- **The phone.** It rings. Whoever picks up gets a tip about what comes next, a minute of cheap seeds, or a wrong
  number. Nobody picks up and the floor is fined.

### 11.4 Next
- A second way the rooms join; a per-shift payment table for full crews (the middle of a run is slack for four);
  more to do in the alley; the scale and the phone as things workers can break.

## 12. M18: talking across the floor, a strain that chokes, saying it without words (2026-10-04)
The user asked for more. What makes a session with friends worth retelling is usually somebody shouting across the
building, somebody coughing in a cloud they walked into, and somebody pointing at the thing everyone else missed.

### 12.1 Radios (now)
- Two walkie-talkies on a shelf. Hold one and talk, and every other radio on the floor carries your voice, crackling,
  wherever it is lying. The worker in the hall can tell the worker at the window what to buy; the worker in the back
  room can still hear the floor; a radio left on the dock tells everyone what the raid is saying.

### 12.2 Black Damp (now)
- A seventh strain from shift three. It pays well and grows slowly, and a ripe tray puffs a cloud of spores when it
  is harvested, uprooted, burnt, shot or hit. Whoever is in the cloud sees grey, hears through cotton and coughs for
  a while; everyone else hears the coughing. Crouch and breathe through your sleeve.

### 12.3 Gestures (now)
- Four keys: point, a tired half-wave, a shrug, sit down against the wall. Nobody smiles and nobody dances.

### 12.4 A fairer payment for a full crew (now)
- The payment for a crew of three or four climbs faster through the run than for one worker, so a full crew is not
  coasting through the middle shifts.

### 12.5 Next
- A second way the rooms join; the Boss's own bad day (a shift where he walks the floor the whole time); a vending
  machine in the alley; breaking the scale and the phone on purpose.
