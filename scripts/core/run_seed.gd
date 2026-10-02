class_name RunSeed
extends RefCounted
## M16 variety: the run code (FRIENDSLOP 10.1, CONTRACTS "M16", "Variety"). Static, pure, no state.
##
## A run has one seed, an int in 1 .. SEED_COUNT (0 = no run: replay off, or no session). Its code is four characters
## from ALPHABET, which has no look-alikes: no 0 / O, no 1 / I / L. Every seed has exactly one code and every code one
## seed, so the code on the alley board is the whole run: type it into the host panel and the host deals the same
## card (conditions, market, jobs, order of events, cover).
##
##   to_code(seed)       "7K2M" (any int folds into the range; 0 or less gives "")
##   from_code(text)     the seed, or 0 for junk (case and spaces ignored: " 7k 2m " is "7K2M")
##   weekly(unix_time)   the seed everyone gets in the ISO week (Monday to Sunday, UTC) `unix_time` falls in
##   stream(seed, name)  an independent sub-seed for one consumer (a RandomNumberGenerator.seed)
##   roll(rng)           a random seed in range
##
## The arithmetic is 32-bit and spelled out (no String.hash(), no overflow), so a code means the same run on every
## machine and in every build.

## 8 digits + 23 letters. Left out: 0 O (each other), 1 I L (each other).
const ALPHABET := "23456789ABCDEFGHJKMNPQRSTUVWXYZ"
const CODE_LENGTH: int = 4
## 31 ** 4: how many codes there are. Seeds are 1 .. SEED_COUNT.
const SEED_COUNT: int = 923521
## Scatter: neighbouring seeds get codes that share nothing ("2222", "2223" would read as a counter). Both are
## coprime to 31, so index * SCATTER_MUL + SCATTER_ADD is a bijection modulo SEED_COUNT; SCATTER_INV undoes the
## multiplication (SCATTER_MUL * SCATTER_INV % SEED_COUNT == 1, pinned by the variety suite).
const SCATTER_MUL: int = 387420
const SCATTER_ADD: int = 271828
const SCATTER_INV: int = 795224
const WEEK_SEC: int = 604800
const DAY_SEC: int = 86400
const MASK32: int = 0xFFFFFFFF


## The run's code: four characters of ALPHABET. Any positive int folds into 1 .. SEED_COUNT first (normalize);
## 0 or less is "no run": "".
static func to_code(run_seed: int) -> String:
	var canonical := normalize(run_seed)
	if canonical == 0:
		return ""
	var value := ((canonical - 1) * SCATTER_MUL + SCATTER_ADD) % SEED_COUNT
	var base := ALPHABET.length()
	var out := ""
	for i in CODE_LENGTH:
		out = ALPHABET[value % base] + out
		@warning_ignore("integer_division")
		value = value / base
	return out


## The seed a code stands for, 0 when `text` is not a code. Case, spaces, tabs and dashes are ignored; anything else
## that is not in ALPHABET (an O, a 1, a fifth character) makes it junk.
static func from_code(text: String) -> int:
	var clean := text.to_upper().replace(" ", "").replace("\t", "").replace("-", "").strip_edges()
	if clean.length() != CODE_LENGTH:
		return 0
	var base := ALPHABET.length()
	var value := 0
	for i in CODE_LENGTH:
		var digit := ALPHABET.find(clean[i])
		if digit < 0:
			return 0
		value = value * base + digit
	var index := posmod(value - SCATTER_ADD, SEED_COUNT) * SCATTER_INV % SEED_COUNT
	return index + 1


## `run_seed` folded into 1 .. SEED_COUNT (a seed already in range is itself); 0 for 0 or less.
static func normalize(run_seed: int) -> int:
	if run_seed <= 0:
		return 0
	return (run_seed - 1) % SEED_COUNT + 1


## True when `text` reads as a code.
static func is_code(text: String) -> bool:
	return from_code(text) != 0


## The seed of the week `unix_time` (seconds, UTC) falls in. ISO weeks: Monday 00:00 UTC to the next. The same for
## everyone in that week, and no two weeks within seventeen thousand years share one.
static func weekly(unix_time: int) -> int:
	# 1 January 1970 was a Thursday: three days into its week.
	var week := floori(float(unix_time + 3 * DAY_SEC) / float(WEEK_SEC))
	return posmod(week * 104729 + 6007, SEED_COUNT) + 1


## An independent sub-seed for the consumer `name` (&"replay:3", &"cover", ...): never 0, always positive, the same
## for the same pair, unrelated for any other pair.
static func stream(run_seed: int, name: StringName) -> int:
	var h := _mix32((run_seed & MASK32) ^ 0x9E3779B9)
	h = _mix32(h ^ ((run_seed >> 32) & MASK32))
	for byte in String(name).to_utf8_buffer():
		h = _mul32(h ^ byte, 0x01000193)
	var hi := _mix32(h ^ 0x85EBCA6B)
	var lo := _mix32(h ^ 0xC2B2AE35)
	var out := ((hi & 0x7FFFFFFF) << 32) | lo
	return out if out != 0 else 1


## A random seed in range from `rng` (the host's pick when no code was asked for).
static func roll(rng: RandomNumberGenerator) -> int:
	return rng.randi_range(1, SEED_COUNT)


## (a * b) mod 2^32 without leaving 64 bits.
static func _mul32(a: int, b: int) -> int:
	var a_lo := a & 0xFFFF
	var a_hi := (a >> 16) & 0xFFFF
	var b_lo := b & 0xFFFF
	var b_hi := (b >> 16) & 0xFFFF
	return (a_lo * b_lo + (((a_hi * b_lo + a_lo * b_hi) & 0xFFFF) << 16)) & MASK32


## The 32-bit finalizer of MurmurHash3: every input bit reaches every output bit.
static func _mix32(value: int) -> int:
	var h := value & MASK32
	h ^= h >> 16
	h = _mul32(h, 0x85EBCA6B)
	h ^= h >> 13
	h = _mul32(h, 0xC2B2AE35)
	h ^= h >> 16
	return h
