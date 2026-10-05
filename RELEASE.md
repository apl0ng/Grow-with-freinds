# Grow With Friends: the road to 1.0

Written 2026-10-05 by the lead, at the user's request: "set goals for yourself and the sub-developers to be able to
release this game with a full enjoyable gameplay loop, ways to disrupt the gameplay loop, and an addictive
playstyle." This file is the target. PLAN.md tracks the tasks; CONTRACTS.md the interfaces; FRIENDSLOP.md the
design reasons. Every milestone below ends with the release bar items it closes.

## What 1.0 is

One to four friends, one evening, one run. A run is four to six shifts against a payment that only goes up, and it
ends: the debt is cleared or the crew starts over. Three things have to be true at release.

1. **The loop is whole.** Buy, plant, water, harvest, cure or not, deposit, pay. A new crew understands it inside
   their first shift without reading anything, and a crew that plays well can clear a run.
2. **The loop gets disrupted, fairly.** Something goes wrong every minute or two: the Boss, the power, the rat, the
   raid, the phone, a plant that gets up and walks, a friend with a ball. Each disruption is seen coming, can be
   answered, and is funny when it is not answered.
3. **One more run.** Every run is different (conditions, market, cover, run code), every run leaves something on
   file (record, titles, hats, debts cleared), and clearing a run opens a harder one.

## The release bar (1.0 ships when every line is true)

### The loop
- L1. A crew with no instructions finishes shift 1 on its first or second try (human playtest, lead watches the
  recording or the user reports).
- L2. The first shift of a first run teaches itself: the Boss says each next step once (buy, plant, water, wait,
  harvest, deposit) until the crew has done it; a player can turn the guidance off.
- L3. Economy model targets hold (`economy` suite): a careful solo worker clears a four-shift run about half the
  time; two careful workers clear five shifts about half the time; three or four careful workers clear six shifts
  with favors and the racks and not without; nobody clears without favors; an average crew reaches the final
  notice and does not clear it.
- L4. A run takes 20 to 35 minutes from the van to PAID IN FULL or START OVER.
- L5. Every strain is the best main strain somewhere and none is dominated (`economy`, `strains`).

### The disruption
- D1. Every disruption meets the quality bar: telegraphed at least 3 s before it costs anything (sound plus banner
  or a visible tell); at least one player action answers it; its expected cost in the model is bounded (no single
  event costs more than 15% of a shift's deposits); its copy is flat and readable in two seconds.
- D2. Three to five disruptions in an average shift, never the same kind twice in a row, growing through the run.
- D3. Player-made disruption is a feature: shove, throw, the ball, the flamethrower, the radio, gestures, and (M21)
  the informant. None of it can lock a player out of playing for more than the back room's 30 s.
- D4. Each disruption is pinned by a suite and captured in the real renderer; each of its sounds has been heard by
  the user.

### The pull
- P1. The end of a run shows what it was worth: a run summary (shifts, deposited, worst moment, who carried, who
  was written up) and what is next on file (the next hat, the next title, the next debt level).
- P2. Clearing a run opens the next **debt level**: the same game with one more modifier each level (M20). The
  record keeps the highest level cleared; each level has its own hat.
- P3. Short-term goals exist inside every shift (the job), across a run (the final notice), and across runs (debt
  levels, hats, titles, achievements, the weekly code).
- P4. Two runs with different codes feel different within the first two shifts.

### The release itself
- R1. The full suite green three runs in a row on the user's PC; no unannounced ERROR line anywhere.
- R2. A four-player session of 45 minutes on real machines (or four local processes) without a desync, a stuck
  player, or a crash; quitting is always clean.
- R3. 60 fps at 1280x720 on the user's PC with four workers during the worst event (sprinklers or the raid);
  headless host tick under 4 ms.
- R4. Settings a player expects: mouse sensitivity, invert Y, field of view, master / effects / voice volume,
  fullscreen and window size, vsync; saved per player; the controls listed in the pause menu.
- R5. The menu shows the version; the zip runs on a clean Windows PC; the firewall prompt flow works; a player
  guide (PLAYER_GUIDE.md, one page) ships in the zip.
- R6. Store-page material: eight screenshots from the capture tools, a 30-second clip, a short description in the
  game's tone. Where it is published is the user's decision (itch.io is the obvious first stop).

## Milestones to 1.0

Each milestone is one wave: lead prep (contracts, lead-only fields), three or four agents in worktrees on Opus
(tools/dev/AGENT_RULES.md), lead integration (merges, captures in the real renderer, the full suite, docs,
export). A wave is not done until its release bar lines are true.

### M18 (in progress): radios, spores, gestures, a fairer payment
- radio: walkie-talkies (merged). spores: Black Damp. emotes: four gestures. economy2: the per-shift team table
  and the solo fix (L3).
- Closes: L3, part of D3.

### M19 "The first ten minutes"
Goal: a new crew gets it without being told, and the game feels like a finished product from the first click.
- **onboarding** agent: the guided first shift (L2): a short list of steps the Boss and the HUD walk through once
  per player record (Career knows whether this player has worked a shift), each step done by the crew advances it,
  a "guidance" toggle in the pause menu; the alley board explains the van once. Suites.
- **settings** agent: an OPTIONS card in the pause menu and the main menu (R4), saved per player in `user://`,
  applied at once; mouse sensitivity moves out of BalanceConfig into the settings; field of view; volume buses
  (Master / SFX / Voice); display. Suites.
- **readability** agent: a HUD and copy pass (L1, D1): every disruption's telegraph checked against the bar (3 s,
  sound, banner, the answer named), the busiest moments captured and decluttered, a short "what just happened"
  line in the shift report for each disruption that cost money. Suites pin the telegraph times.
- **lead**: the version string in the menu (R5), the capture pass of a whole first run, a disruption audit table
  in CONTRACTS ("M19 as delivered": every event, its telegraph, its answer, its modelled cost).
- Closes: L1 (pending a human playtest), L2, R4, part of D1 and R5.

### M20 "One more run"
Goal: the end of a run pulls the crew into the next one.
- **debt** agent: debt levels (P2): clearing a run at level N opens N + 1 for that host (record); a level picker in
  the alley (the board, or a second van door); each level adds one modifier from a list (a higher payment, an extra
  condition every shift, the Boss walks more, shorter shifts, the market swings wider, events come sooner, no
  favors at the window...), the run code includes the level; a hat per level up to 5.
- **summary** agent: the run summary screen (P1): after PAID IN FULL or a missed payment, a page with the run's
  numbers, the three worst moments (from the events and verdicts), per-worker lines, and "next on file"; personal
  bests per run code and per debt level in the career file.
- **achievements** agent: twenty achievements in the career file, flat names (e.g. "Paid on the buzzer",
  "Nobody saw anything", "Burnt the whole floor"), shown on the Record card; three of them issue hats.
- **economy3** agent: the model extended to debt levels; each level's modifier tuned so level 3 is cleared by a
  careful full crew about half the time and level 5 rarely.
- Closes: P1, P2, P3.

### M21 "The informant"
Goal: the friends themselves become the disruption (D3), the one mode people will talk about afterwards.
- **informant** agent: an optional mode for three or four players (host toggle in the alley): at the start of a
  run one worker is secretly the informant. They see a private line, earn their own record by getting others
  written up (a "tip" key near a worker holding product calls the Boss's attention) and by the crew missing a
  payment; the crew wins by clearing the run, and at any shift report can accuse one worker (a vote; a wrong
  accusation costs cash on hand). The reveal is on the run summary. Tone: flat, nobody laughs.
- **informant_net** agent (or the same agent, if small enough): the secret is sent only to that client; no peer can
  learn it from the wire before the reveal; late joiners are never made the informant.
- **economy** follow-up: the informant's cost in the model, so a crew with an informant still clears sometimes.
- Closes: D3; adds P4 for groups of three and four.

### M22 "Release hardening"
Goal: nothing breaks in front of the user's friends.
- **perf** agent: a profiling run (R3) on the worst moments with four workers; fixes for anything over budget
  (particles, lights, the spore cloud, the raid beams, voice outputs).
- **soak** agent: a 45-minute four-process soak with simulated latency and packet loss (R2); host leaves, client
  rejoins, the van, the final notice; every error found is fixed or announced.
- **ship** agent: PLAYER_GUIDE.md, the zip layout, the version, a clean-PC check list, the store-page material
  (screenshots from the capture tools, a clip from a scripted capture), credits (everything here is made for this
  game: procedural sound, Blender-built models, one font).
- **lead**: the full suite three times in a row (R1), the capture pass of a whole run per team size, the release
  notes.
- Closes: R1, R2, R3, R5, R6.

### Release candidate and 1.0
- The user and friends play the release candidate: two evenings, one with two players and one with four. The lead
  turns every report into a fix or a decision before 1.0.
- The user auditions every sound in `export/audition` (D4) and decides the publishing channel and price (R6).

## Standing goals

### The lead (this session)
- Keep the release bar honest: a line is true only when a suite or a capture or the user says so.
- Prep every wave so agents never wait on each other: contracts first, lead-only fields and stubs, one region per
  agent per shared file, test ports assigned up front.
- Merge every branch the day it reports; read its "decisions to review" and decide them in writing (CONTRACTS
  "as delivered"); never merge a deviation silently.
- See everything rendered: a capture tool per wave; nothing ships that nobody has looked at in the real renderer.
- Keep the user's launch copy playable at all times: integrate in a worktree, fast-forward the main checkout only
  when the full suite is green and the game is closed.
- Report to the user in plain words: what changed in the game, what they should try, what they need to decide.

### Every sub-developer
- Work in your own worktree from the base commit you are given; follow tools/dev/AGENT_RULES.md.
- Your feature is done when: its suite(s) pass five times in a row, its neighbours' suites pass, every number a
  player will feel is in BalanceConfig, its copy follows STYLE.md, its multiplayer path is server-authoritative and
  validated, late joiners see the right state, reset / menu / quit leave nothing behind, and your report lists
  every deviation and every decision for the lead.
- Prefer a small, finished, tested feature over a big unfinished one; say what you left out.

### The user
- Play: the release candidate with friends (L1, R2), and any build in between when you feel like it.
- Listen: the sounds in `export/audition` (D4); tell the lead which ones are wrong.
- Decide: the publishing channel and price, whether the informant mode ships on by default, and anything the lead
  puts in front of you as a decision.

## Out of scope for 1.0
- Host migration, matchmaking and NAT traversal (friends join by IP; UDP 7777 forwarded for internet play).
- Controller support, localisation, more than four players, a second building layout. All are candidates for 1.1.
