# Grow With Friends

4-player co-op first-person quota game. Plant, water, grow, harvest and sell to hit the team quota before the timer
runs out. Godot 4.7.2 / GDScript, ENet multiplayer, server-authoritative.

See **PLAN.md** (status, decisions, how to test), **CONTRACTS.md** (system interfaces), **STYLE.md** (art rules).

## Run
- Open in Godot 4.7.x and press Play (main menu → Host or Join by IP).
- Local multiplayer test: `godot --path . -- --host --name=Alice` and `godot --path . -- --join=127.0.0.1 --name=Bob`.
- Quick balance: `--fast` makes growth 20x faster and rounds 60 s.

## Validate headless
`tools/check.sh`
