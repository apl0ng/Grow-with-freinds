class_name Radio
extends Item
## A walkie-talkie (M18 radio; scenes/items/radio.tscn, model art/models/radio.glb, CONTRACTS "M18", "Radio"). An
## ordinary item (Const.ITEM_RADIO): picked up, dropped and thrown like any other; a thrown radio that hits a worker
## staggers them (ItemManager's flight step). It has no props and nothing about it is synced beyond the base item.
##
## Where they are. Config.balance.radio_count of them stand on the radio shelf on the main room's north wall
## (Room `Decor/RadioShelf/Spot`, scripts/items/radio_spot.gd). The host spawns them there when the first shift starts
## (server_stock); at every later shift start a radio lying outside the building's play areas (left in the alley) goes
## back to the shelf and a missing one is replaced; START OVER despawns them all (server_despawn_all) and the next
## shift's start stocks the shelf again. The raid, the collector, the rat and the Boss deal in product: a radio is
## never taken. A power cut does not touch it (batteries).
##
## Talking through it is Voice's job (scripts/core/voice.gd, "M18 radio" region): a worker holding a radio who talks
## is heard, besides the proximity voice, at every OTHER radio wherever it is (Voice parents its generator outputs
## under the receiving radio nodes). Voice drives this node's cosmetics on every peer:
##   play_click(true / false)   the radio_on / radio_off click here (both ends, when a transmission starts / stops)
##   set_receiving(on)          the quiet radio_static loop here while a transmission comes in, the lamp lit
##   set_sending(on)            the lamp lit while its holder transmits through it
##   stop_sounds()              everything off (Voice.shutdown: audio is released before quitting)
## The click and the static play on this radio's own players (children "RadioClick" / "RadioStatic", the SFX bus):
## Sfx.play() swallows a second play of the same sound within 40 ms, and a transmission clicks at two radios at once.

const SOUND_ON: StringName = &"radio_on"
const SOUND_OFF: StringName = &"radio_off"
const SOUND_STATIC: StringName = &"radio_static"
## The lamp node in the model (radio.glb `Led`), lit by a material override.
const LED_PATH := ^"Visual/Led"
## Where the radio's speaker is (local): the clicks and the static come from here.
const SPEAKER_OFFSET := Vector3(0.0, 0.2, 0.0)
const SPEAKER_UNIT_SIZE := 5.0
const SPEAKER_MAX_DISTANCE := 45.0
const DISPLAY_NAME := "Radio"

var _click: AudioStreamPlayer3D = null
var _static: AudioStreamPlayer3D = null
var _receiving: bool = false
var _sending: bool = false
var _clicks_on: int = 0
var _clicks_off: int = 0
var _led_lit_mat: Material = null


func _ready() -> void:
	super()
	_build_speakers()
	_refresh_led()


func _exit_tree() -> void:
	stop_sounds()
	super()


func get_display_name() -> String:
	return DISPLAY_NAME


# --- cosmetics (every peer; Voice calls these) ---------------------------------------------------------------------

## The radio_on (on) / radio_off click at this radio.
func play_click(on: bool) -> void:
	if on:
		_clicks_on += 1
	else:
		_clicks_off += 1
	if _click == null or not is_inside_tree():
		return
	var stream := _sfx_stream(SOUND_ON if on else SOUND_OFF)
	if stream == null:
		return
	_click.stop()
	_click.stream = stream
	_click.volume_db = _sfx_volume(SOUND_ON if on else SOUND_OFF)
	_click.play()


## While a transmission comes in: the static loop under it and the lamp lit.
func set_receiving(on: bool) -> void:
	if on == _receiving:
		return
	_receiving = on
	if _static != null and is_inside_tree():
		if on:
			var stream := _sfx_stream(SOUND_STATIC)
			if stream != null:
				_static.stream = stream
				_static.volume_db = _sfx_volume(SOUND_STATIC)
				_static.play()
		else:
			_static.stop()
	_refresh_led()


func is_receiving() -> bool:
	return _receiving


## While its holder transmits through it: the lamp lit.
func set_sending(on: bool) -> void:
	if on == _sending:
		return
	_sending = on
	_refresh_led()


func is_sending() -> bool:
	return _sending


## True while the lamp is lit (sending or receiving).
func is_lit() -> bool:
	return _sending or _receiving


## How many radio_on (on) / radio_off clicks this radio played since it spawned (tests).
func get_click_count(on: bool) -> int:
	return _clicks_on if on else _clicks_off


## True while the static loop plays here (tests).
func is_static_playing() -> bool:
	return _static != null and _static.playing


## Everything off and the streams released (Voice.shutdown, leaving the tree).
func stop_sounds() -> void:
	_receiving = false
	_sending = false
	for p: AudioStreamPlayer3D in [_click, _static]:
		if p != null and is_instance_valid(p):
			if p.is_inside_tree():
				p.stop()
			p.stream = null
	if is_inside_tree():
		_refresh_led()


# --- the shelf (host) -------------------------------------------------------------------------------------------------

## SERVER. Stocks the shelf at a shift's start: `slots` (global transforms on the shelf, one per radio; a radio there
## is turned to the slot's yaw, its face towards the slot's -Z). A radio that nobody holds and that lies outside the
## room's play areas (`room.contains_point`; none = every radio counts as home) goes back to a free slot; then radios
## are spawned at free slots until there are slots.size() of them. Held radios and radios lying in the building stay
## where they are. Returns every radio there is afterwards.
static func server_stock(items: ItemManager, slots: Array[Transform3D], room: Node = null) -> Array[Radio]:
	var out: Array[Radio] = []
	if items == null or not items.is_inside_tree() or not items.multiplayer.is_server():
		return out
	var radios: Array[Radio] = []
	for item in items.get_items_of_type(Const.ITEM_RADIO):
		if item is Radio:
			radios.append(item as Radio)
	var free: Array[Transform3D] = []
	for slot in slots:
		var taken := false
		for r in radios:
			if not r.is_held() and not r.is_flying() and r.global_position.distance_to(slot.origin) < 0.05:
				taken = true
				break
		if not taken:
			free.append(slot)
	for r in radios:
		if free.is_empty():
			break
		if r.is_held() or r.is_flying() or _is_home(r.global_position, room):
			continue
		var slot: Transform3D = free.pop_front()
		items.server_drop_item(r, slot.origin)
		r.server_set_rest(r.rest_position, Vector3(0.0, slot.basis.get_euler().y, 0.0))
	var count := radios.size()
	while count < slots.size() and not free.is_empty():
		var slot: Transform3D = free.pop_front()
		var r := items.server_spawn_item(Const.ITEM_RADIO, {}, slot.origin) as Radio
		if r == null:
			break
		r.server_set_rest(r.rest_position, Vector3(0.0, slot.basis.get_euler().y, 0.0))
		radios.append(r)
		count += 1
	out.assign(radios)
	return out


## SERVER. Despawns every radio (START OVER). Returns how many.
static func server_despawn_all(items: ItemManager) -> int:
	if items == null or not items.is_inside_tree() or not items.multiplayer.is_server():
		return 0
	var n := 0
	for item in items.get_items_of_type(Const.ITEM_RADIO):
		items.server_despawn_item(item)
		n += 1
	return n


## True when `point` lies in one of the room's play areas (a room without the M14 API: always).
static func _is_home(point: Vector3, room: Node) -> bool:
	if room == null or not is_instance_valid(room) or not room.has_method(&"contains_point"):
		return true
	return bool(room.call(&"contains_point", point, 0.0))


# --- internals -------------------------------------------------------------------------------------------------------

func _build_speakers() -> void:
	_click = _make_speaker("RadioClick")
	_static = _make_speaker("RadioStatic")


func _make_speaker(node_name: String) -> AudioStreamPlayer3D:
	var p := AudioStreamPlayer3D.new()
	p.name = node_name
	p.position = SPEAKER_OFFSET
	p.bus = _sfx_bus()
	p.attenuation_model = AudioStreamPlayer3D.ATTENUATION_INVERSE_DISTANCE
	p.unit_size = SPEAKER_UNIT_SIZE
	p.max_distance = SPEAKER_MAX_DISTANCE
	p.doppler_tracking = AudioStreamPlayer3D.DOPPLER_TRACKING_DISABLED
	add_child(p)
	return p


func _refresh_led() -> void:
	var led := get_node_or_null(LED_PATH) as MeshInstance3D
	if led == null:
		return
	if is_lit():
		if _led_lit_mat == null:
			_led_lit_mat = Toon.material(Toon.lighter(Toon.ERROR, 0.2), Toon.Finish.FLAT)
		led.material_override = _led_lit_mat
	else:
		led.material_override = null


static func _sfx_bus() -> StringName:
	return Sfx.BUS_NAME if AudioServer.get_bus_index(Sfx.BUS_NAME) != -1 else &"Master"


static func _sfx_stream(sound: StringName) -> AudioStream:
	if not Sfx.enabled or not Sfx.has_sound(sound):
		return null
	return Sfx.get_stream(sound)


## The sound's SETTINGS volume (plus Sfx.volume_db when there is no SFX bus to carry it).
static func _sfx_volume(sound: StringName) -> float:
	var s: Array = Sfx.SETTINGS.get(sound, [-10.0, 0.0, SPEAKER_UNIT_SIZE])
	var vol: float = s[0]
	if AudioServer.get_bus_index(Sfx.BUS_NAME) == -1:
		vol += Sfx.volume_db
	return vol
