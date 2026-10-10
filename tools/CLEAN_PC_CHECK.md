# Clean-PC check

For RELEASE.md R5 ("the zip runs on a clean Windows PC; the firewall prompt flow works"). Run it on a friend's PC that
has never had Godot or this project on it, with a second PC on the same network for the join. Tick each box, write
down anything that differs, and send back the notes, the screenshots of anything that went wrong and the log file
(step 9). About twenty minutes.

You need: the zip (`GrowWithFriends-<version>-win64.zip`; the old name `GrowWithFriends-win64.zip` is the same file),
PC A (the clean one, it hosts), PC B (any Windows PC with the same zip, it joins), a headset with a microphone on each.

## 1. The download
- [ ] Copy or download the zip to PC A. Note its size: ______ MB.
- [ ] A browser that warns ("not commonly downloaded"): choose Keep. Note the browser and the wording.

## 2. Unzip
- [ ] Right-click the zip, Extract All, into a folder of its own (Desktop is fine).
- [ ] The folder holds `GrowWithFriends.exe`, `PLAYER_GUIDE.md` and `README.txt`. README.txt names the version.
- If Windows will not extract: the disk is full or the path is too long. Extract to `C:\GWF` and try again.
- Do not start the game from inside the zip window: the firewall rule of step 5 would point at a temporary copy.

## 3. First start: SmartScreen and the antivirus
- [ ] Double-click `GrowWithFriends.exe`.
- [ ] Expected: a blue "Windows protected your PC" box (the exe is not signed). Click More info, then Run anyway.
  Note whether it appeared.
- No Run anyway button (a managed or school PC): close it, right-click the zip, Properties, tick Unblock, OK, and
  extract again. If that is not allowed either, this PC cannot run unsigned games: note it and use another PC.
- An antivirus quarantines the exe: note the product and the detection name, restore it, allow the file. Unsigned
  Godot games are flagged now and then. This is a finding for the release, not something to fix on the spot.
- [ ] Expected: a window titled "Grow With Friends", the main menu, `v<version>` in grey under the title.
- Nothing opens, or it closes at once: update the graphics driver and try again. The game needs Vulkan or
  Direct3D 12 (Godot's Forward+ renderer). Send the log (step 9) either way.
- It opens but looks flat or wrong: the log's first lines name the renderer. "Vulkan" or "D3D12" is right;
  "OpenGL" means Godot fell back to its compatibility renderer, which this game was never tested on. Note it.

## 4. The network prompt on first start
The menu listens for floors on the local network (UDP 7778), so Windows may ask on the first start, before
anyone hosts.
- [ ] A "Windows Security" box about the firewall: tick Private networks (and Public if this PC's network is set
  to Public), click Allow access. Note the program name it shows (it may read "Godot Engine": the exe still
  carries the engine's name and icon).
- Someone clicked Cancel: Windows then blocks the game, and a block wins over the allow rule of step 5. Fix:
  Windows Security, Firewall & network protection, Allow an app through firewall, Change settings, find the game
  (or "Godot Engine"), tick Private (and Public), OK. Or Advanced settings, Inbound Rules, delete the Block rules for
  `GrowWithFriends.exe`. Restart the game.

## 5. Host on PC A
- [ ] Type a name, press **Open the floor**. The status line reads "Checking Windows Firewall…".
- [ ] Expected: a User Account Control box: "Do you want to allow this app to make changes to your device?",
  Windows Command Processor, verified publisher Microsoft Windows. That is the game adding one inbound rule (UDP
  7777, this exe only). Click Yes.
- [ ] Expected: "Windows Firewall allows UDP port 7777." on the menu and again as a note in the game, then the alley
  with the van.
- [ ] Check the rule: Windows Defender Firewall, Advanced settings, Inbound Rules: "Grow With Friends Multiplayer UDP
  7777", enabled, Allow, UDP, local port 7777, program = the exe in the folder of step 2.
- Clicked No: "Windows Firewall may block friends from joining: administrator permission was declined. Hosting
  anyway." The game still hosts. Esc, CLOCK OUT (MAIN MENU), press **Allow UDP 7777 through Windows Firewall**, Yes.
- Not an administrator account: the box asks for an administrator's password. Without one, an administrator runs
  this once in a Command Prompt opened as administrator (the folder path changed to the real one):
  `netsh advfirewall firewall add rule name="Grow With Friends Multiplayer UDP 7777" dir=in action=allow protocol=UDP localport=7777 profile=any enable=yes program="C:\GWF\GrowWithFriends.exe"`
- "Windows Firewall could not be configured (…)": write down the text in the brackets.
- "Could not host on port 7777 (…). Is it already in use?": another copy of the game is open. Close it.
- Moving the folder later points the rule at the old place: the next Open the floor asks once more. That is expected.

## 6. Join from PC B
- [ ] On PC B, start the game (steps 3 and 4 apply there too). Within a few seconds **Floors open nearby** lists
  "<name>'s floor · 1/4 · <address>:7777". Double-click it.
- [ ] Also try by IP once: type the address PC A's menu shows ("Your address for friends: …") under Host IP, port
  7777, **Report for shift**.
- [ ] Expected: the alley. Each of you sees the other with a name above the head; the HUD lists two workers.
- [ ] Both get into the back of the van: "Doors closing", a fade, the loading dock. Work a few minutes: buy, plant,
  water, deposit. The other worker moves smoothly; what one picks up, the other sees in their hands.
- The list stays empty: the PCs are not on the same network, or the network is a guest network that keeps devices
  apart, or step 4 was cancelled on PC B. Join by IP instead and note it.
- "Could not connect to … (timed out). Is the host running and the port open?": on PC A check the rule (step 5) and
  step 4; a VPN on either PC, or another firewall (an antivirus suite with its own firewall), blocks it: allow
  `GrowWithFriends.exe` there. Note which one it was.
- "Server is full (4/4 players)": four are already in.
- Over the internet (optional): PC A's router forwards UDP 7777 to PC A; PC B types PC A's public address. If it
  times out with the forward in place, the provider may share one public address between customers (CGNAT): note
  it. There is no way around that in this version.

## 7. Voice and radios
- [ ] On both PCs: Esc, the VOICE card: Microphone on, Push to talk (V) on, the input meter moves while you speak.
- "No microphone found.": Windows Settings, Privacy & security, Microphone: Microphone access on and "Let desktop
  apps access your microphone" on; check the default input device under Sound. Restart the game.
- [ ] Stand near each other, hold V and talk: the other PC hears you, quieter with distance (about 14 metres), and
  a "))" mark shows next to your name in its WORKERS list.
- Nothing heard: the Voices slider in OPTIONS and the voice volume on the VOICE card on the listening PC, and the
  Windows volume. Note it if the meter moves on one PC and nothing arrives on the other.
- [ ] Each picks up a radio from the shelf by the phone. Walk apart, hold V: the other radio crackles with your voice.

## 8. Quit
- [ ] PC B: Esc, CLOCK OUT (MAIN MENU), then **Walk out (you can't)**. The window closes within a few seconds.
- [ ] PC A: Esc, CLOCK OUT (MAIN MENU) while PC B is still in, on another try: PC B goes back to its menu with "Host
  disconnected". Then Walk out.
- [ ] Task Manager, Details: no `GrowWithFriends.exe` left on either PC. Closing with the window's X also quits.
- A process that stays: End task, note what you did last, send the log.

## 9. What the game left on the PC
- `%APPDATA%\Godot\app_userdata\Grow With Friends\`: settings.cfg (OPTIONS, the menu's name and address), career.cfg
  (the record and hats), voice.cfg, gwf_firewall_rule.ps1 (the firewall helper; it deletes its result file itself), and
  `logs\godot.log` (send this one).
- The firewall rule of step 5, and the Allow entry of step 4 if one was made.
- To remove it all: delete the game's folder, the app_userdata folder above, and the rule (Advanced settings,
  Inbound Rules, "Grow With Friends Multiplayer UDP 7777"). Nothing else is installed.
