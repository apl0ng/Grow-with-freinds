# Disruption audit (M19 readability)

Every disruption against RELEASE.md D1: at least 3 s between the first sign (sound + banner, or a visible tell) and the
first cost; a player action answers it; the hint names the answer; every line reads in two seconds. **Before** is the
game as of M18 (a bare `Events.server_start_event`, which the older suites still use); **after** is what the scheduler
starts now (`Events.server_start_scheduled`: the kind's tell, `Events.READ_TELL_SEC`). Seconds are measured by
`tools/tests/readability_body.gd` (it prints them as `AUDIT|` lines) with a worker doing the worst thing: standing in
the Boss's sight with a bundle, sprinting through the puddle, standing in a lane, leaving a bundle in the open, never
answering. Real-time measures (the Boss's walk, the rat's run) land within a frame of the value shown.

| Disruption | First sign | Before (s) | After (s) | Answer (the hint) | Copy (title / hint / toast / Boss) | Worst-case cost |
|---|---|---|---|---|---|---|
| Inspection | `alarm`, banner, the Boss's line, his `keys` loop, the Boss leaving the booth | **2.0** first write-up (sight passes from 0.5 s) | **3.0** (nobody is judged during the tell) | Empty hands, keep moving: "Hands empty. Keep moving." (new) | INSPECTION / Hands empty. Keep moving. / none / "Walking the floor. Don't make me stop." | $25 + the bundle per worker caught, once per 5 s; 3 strikes = 30 s in the back room |
| Power cut | `alarm`, banner; now the lights flicker and the hum drops out for the tell | **0.0** growth stops at once | **3.0** the mains go when the flicker ends | Hold E at the fuse box: "Find the breaker." | POWER CUT / Find the breaker. / none / "Not my problem." | Growth and water drain stop up to 40 s (80 s with bad wiring); no money |
| Audit | `alarm`, banner; now "AUDIT 0:08" counts down to the count | **0.0** +10% of the payment, no answer | **8.0** then +10% of what is still owed | Deposit during the countdown: "Deposit before he counts." (new), then "Payment due up $X." | AUDIT / Deposit before he counts. / "Audit: payment due up $35." / "Audit. I count what you still owe." then "The number went up." | 10% of the payment due (nothing deposited yet); less for every deposit made in the countdown |
| Rat | `alarm`, banner, the squeaks, the rat running from the gap | **1.7** it eats (nearest tray: its run) | **3.0** it waits at the tray until the tell is over | Walk up to it (1.5 m): "Chase it off the tray." (new) | RAT / Chase it off the tray. / none / "Rats. Not my problem either." | 0.06 of a stage per second for up to 30 s: one tray set back, never lost |
| Head count | `headcount` sound, banner, the Boss walking to the line | **15.0** | **15.0** (no tell needed) | Stand at the line: "The line. In front of the window." | HEAD COUNT / The line. In front of the window. / none / "Head count. The line. Now." | $25 and a strike per absent worker |
| Water off | `water_off` at the tank, banner; now the pipes knock for the tell | **0.0** refills refused | **5.0** (the tank still fills cans meanwhile) | Fill the cans now, then use them: "Fill the cans. Now." / "No pressure. Use the cans." (new) | WATER OFF / (as answer) / none / "Water main goes off. Fill the cans." then "Water main is off." | No refills for 30 s (trays dry out if nobody filled a can) |
| Shortage | `shortage` at the window, banner | refusal at 0.0, **no cost** | same | Buy another strain: "Night Shift is out. Buy another." (was "... is out of stock.") | SHORTAGE / %s is out. Buy another. / none / "No more Night Shift this shift." | Nothing lost: one strain cannot be bought for 45 s |
| Leak | `alarm`, toast, banner, the jet and the puddle, the `leak` loop | **0.30** first slip in the fresh puddle; the tank empty at **45.0** | **3.05** first slip; the tank at **45.0** | Hold E on the tank (2.5 s): "Hold E on the tank."; walk in the puddle | LEAK / Hold E on the tank. / "The tank is leaking. Hold it shut." / "The tank is leaking. Somebody hold it shut." | The tank empty 60 s; slips (0.8 s down, the held item dropped) |
| Drive-by | `tires` outside, toast, banner | **2.65** first round (2.5 s warning) | **3.65** (3.5 s warning; lead: `driveby_warning_sec` 2.5 -> 3.5) | Crouch: "Get down." | DRIVE-BY / Get down. / "Drive-by. Get down." / "Get down." then "Glass and holes: thirty. Out of cash on hand." | Standing workers knocked down (1.0 s), each growing tray in a lane set back 0.35 of a stage, $30 bill |
| Raid | `siren` loop, red and blue lights at the roller door, toast, banner | **20.0** first look | **20.0** | Hide the product (walls, crates, the hall, the chute): "Get the product out of sight." | RAID / Get the product out of sight. / "Raid. Get the product out of sight." / "They are outside. Get it out of sight." | Every bundle in sight of four looks (and a truck's whole load); $25 per worker holding one |
| Sprinklers | `sprinkler` loop, water falling in every area, toast, banner | **0.30** first slip | **3.05** first slip (the floor is not slippery during the tell) | Walk, do not run: "Wet floor. Do not run." | SPRINKLERS / Wet floor. Do not run. / "Sprinklers. Everything is watered. Do not run." / same | Slips for 35 s (0.8 s down, the held item dropped); every tray is watered (a gain) |
| Collection | `collector_knock`, toast, banner, the man walking onto the dock | **25.0** he takes something | **25.0** | Hold E on him (1.5 s): "He wants $40. Dock." | COLLECTION / He wants $40. Dock. / "Collection. He wants $40. He is on the dock." / "He wants forty. He is on the dock." | $40 paid; unpaid: the dearest bundle on the floor or the most advanced tray |
| Scale | `alarm`, toast, banner | **0.0** deposits pay 15% less | **3.0** (deposits pay in full during the tell) | F at the chute or throw something at it: "It reads light. Hit it." | SCALE IS OFF / It reads light. Hit it. / "The scale reads light: 15% less. Hit the chute (F)." (was 17 words) / "The scale reads light. Somebody hit it." | 15% of every deposit for 40 s |
| Phone | `phone_ring` at the phone, the handset rattling, toast, banner | **14.0** the fine | **14.0** | Hold E on the phone (1.2 s): "Somebody pick that up." | PHONE / Somebody pick that up. / "The phone is ringing. Somebody pick that up." / "That's the phone. Pick it up." | $30 (a favor or a tip lost) |
| Hostile plant | the tray twitches on every peer, status "Moving", toast, the Boss | crop lost **6.0**, first bite **8.1** | same (the toasts now name the answer) | Harvest it while it twitches; once out, keep clear or burn it: "GrowPlot 3 is moving. Harvest it." / "Something came out of GrowPlot 3. Burn it." | (no banner) / (the toasts) / as answer / "GrowPlot 3 is moving." | The tray (+$25 for Golden Kush), a 1.0 s bite with the held item dropped, two more trays eaten (4 s each) |
| Black Damp spores | the motes over the tray | **0.0** the motes came at READY, a harvest could puff at once | **3.5** the motes start before it ripens; a toast once a shift | Crouch (half the fog) or keep 2.6 m away: "Black Damp is ripening. Crouch near it." (new) | (no banner) / (the toast) / as answer / "That's the damp, Dale. Cough on your own time." | 9 s of fog (grey screen, muffled hearing, coughing) per worker in the cloud; no money |
| Flamethrower | `glass_break`, "Glass broke.", now a toast "Dale broke the glass. Flamethrower out.", the item in hand, the `flame` loop | **0.0** a worker in the cone is lit at once | **0.0** (player-made, RELEASE D3; not changed) | Stay out of its 3.5 m reach | (no banner) / (the toast) / "Dale broke the glass. Flamethrower out." / "Glass broke." | 0.5 s stun + the held item for a worker; a crop after 0.5 s of flame; the shooter pays $25 a write-up and goes to the back room on the third |

## Notes

- **The tell is the scheduler's.** `Events.server_start_scheduled(kind)` (the scheduler, `request_event`) passes
  `{"tell": READ_TELL_SEC[kind]}`; the event's params then carry `tell` and `total`. A bare `server_start_event(kind)`
  behaves as before M19, so the older suites keep their pins. The game only ever starts events through the scheduler.
- **The audit's answer** changes its cost: with a tell it raises the payment by `audit_raise_fraction` of what is still
  owed at the count, not of the whole payment (the same at the start of a shift, less later). The economy model still
  prices it at 10% of the payment: a little pessimistic.
- **The drive-by's 3.5 s** is pinned by `READ_TELL_SEC` until the lead raises `driveby_warning_sec` in BalanceConfig.
- **Copy limits** (pinned): a title 14 characters, a hint 7 words / 34 characters with its answer in it, a toast or a
  Boss line 10 words / 60 characters, no "!". Three lines were too long and are shorter now: the drive-by's bill, the
  missed call's short line and the scale's toast.
- **What it cost.** The host books every disruption's cost in a ledger (`Events.get_shift_costs()`, synced whole); the
  shift report shows `Story.get_shift_cost_lines()`: at most three, the dearest first ("The raid took two bundles of
  Golden Kush. $250.", "The collector took $40.", "The audit put $35 on the payment.").
- **The busiest moments** at 1280x720 (toasts three at most, the GO banner under the payment column) are measured by
  `HUD.get_read_blocks()` in the readability suite; `tools/tests/m19_shots_body.gd` captures them on the real renderer.
