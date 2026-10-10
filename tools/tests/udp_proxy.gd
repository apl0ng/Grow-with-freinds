extends SceneTree
## UDP proxy for the soak (M22 soak agent, CONTRACTS "M22", "Soak"): sits between game clients and the host and makes
## the link bad on purpose. Every datagram is forwarded both ways after a delay, with jitter, and some are dropped.
## A plain -s script (no autoloads): it never loads the game.
##
##   godot --headless --path . -s res://tools/tests/udp_proxy.gd -- --listen=9209 --host=127.0.0.1:9208 \
##       --delay-ms=80 --jitter-ms=20 --loss=0.02 --seed=7 [--max-sec=900] [--quit-file=<path>] [--reorder]
##       [--stats-sec=30] [--idle-sec=120]
##
## Clients connect to 127.0.0.1:<listen>. Each client address (ip:port) gets its own session: an upstream socket bound
## to an ephemeral local port that talks to the host, so the host sees one ENet peer per client, and a client that
## leaves and joins again (a new ENet socket, a new source port) is a new session.
##   --delay-ms    one-way delay added to every datagram in each direction (a round trip gains twice this)
##   --jitter-ms   each datagram's delay is delay +- a uniform amount up to this
##   --loss        the chance (0..1) that a datagram is dropped, decided per datagram and direction
##   --seed        seeds the dice: session N's client->host dice use seed*1000+2N, host->client seed*1000+2N+1, so
##                 the same traffic in the same order meets the same delays and drops
##   --reorder     let jitter reorder datagrams (default: each direction stays first-in first-out, the way a real
##                 queue behind a slow link behaves: a datagram never leaves before the one in front of it)
##   --max-sec     exit after this many seconds (default 1800)
##   --quit-file   exit as soon as this file exists (any path Godot can read: user://, res:// or absolute)
##   --stats-sec   print a counters line this often (default 30; 0 = only at the end)
##   --idle-sec    forget a session after this long without traffic (default 120)
## Prints "UDP_PROXY_READY <listen>" once the socket is bound and "UDP_PROXY_DONE ..." with the totals at the end.
## Exit code 0 on a clean stop (quit file, max-sec), 2 on bad arguments or a port it cannot bind.

const DIR_UP := 0    # client -> host
const DIR_DOWN := 1  # host -> client
const MAX_PER_FRAME := 512

var _listen_port: int = 0
var _host_ip: String = "127.0.0.1"
var _host_port: int = 0
var _delay_usec: int = 0
var _jitter_usec: int = 0
var _loss: float = 0.0
var _seed: int = 1
var _reorder: bool = false
var _max_usec: int = 1800 * 1000000
var _quit_file: String = ""
var _stats_usec: int = 30 * 1000000
var _idle_usec: int = 120 * 1000000

var _listen: PacketPeerUDP = null
## "ip:port" -> session Dictionary: {key, ip, port, index, up (PacketPeerUDP), rng: [up, down], queue: [up, down],
## free_at: [up, down], last_usec}
var _sessions: Dictionary = {}
var _session_count: int = 0
var _t0_usec: int = 0
var _next_stats_usec: int = 0
var _next_quit_check_usec: int = 0
var _done: bool = false
## Counters: [forwarded, dropped, bytes] per direction.
var _fwd: Array[int] = [0, 0]
var _drop: Array[int] = [0, 0]
var _bytes: Array[int] = [0, 0]


func _initialize() -> void:
	if not _parse_args():
		_done = true
		quit(2)
		return
	_listen = PacketPeerUDP.new()
	var err := _listen.bind(_listen_port, "127.0.0.1")
	if err != OK:
		printerr("udp_proxy: cannot bind 127.0.0.1:%d (%s)" % [_listen_port, error_string(err)])
		_done = true
		quit(2)
		return
	# A millisecond of resolution is plenty for tens of milliseconds of delay, and spares a CPU core.
	Engine.max_fps = 1000
	_t0_usec = Time.get_ticks_usec()
	_next_stats_usec = _t0_usec + _stats_usec if _stats_usec > 0 else 0
	print("udp_proxy: 127.0.0.1:%d -> %s:%d, delay %d ms +- %d, loss %.3f, seed %d, %s" % [_listen_port, _host_ip,
			_host_port, _delay_usec / 1000, _jitter_usec / 1000, _loss, _seed, "reordering" if _reorder else "first-in first-out"])
	print("UDP_PROXY_READY %d" % _listen_port)


func _process(_delta: float) -> bool:
	if _done:
		return true
	var now := Time.get_ticks_usec()
	_receive_from_clients(now)
	for key in _sessions.keys():
		var s: Dictionary = _sessions[key]
		_receive_from_host(s, now)
		_flush(s, DIR_UP, now)
		_flush(s, DIR_DOWN, now)
		if now - int(s["last_usec"]) > _idle_usec and (s["queue"][DIR_UP] as Array).is_empty() and (s["queue"][DIR_DOWN] as Array).is_empty():
			print("udp_proxy: session %d (%s) idle, closed" % [int(s["index"]), key])
			(s["up"] as PacketPeerUDP).close()
			_sessions.erase(key)
	if _next_stats_usec > 0 and now >= _next_stats_usec:
		_next_stats_usec = now + _stats_usec
		print("udp_proxy: " + _stats_line(now))
	if now - _t0_usec >= _max_usec:
		_stop("max-sec reached")
		return true
	if _quit_file != "" and now >= _next_quit_check_usec:
		_next_quit_check_usec = now + 100000
		if FileAccess.file_exists(_quit_file):
			_stop("quit file found")
			return true
	return false


func _finalize() -> void:
	if _listen != null:
		_listen.close()
	for key in _sessions.keys():
		(_sessions[key]["up"] as PacketPeerUDP).close()
	_sessions.clear()


# --- forwarding ------------------------------------------------------------------------------------------------------

func _receive_from_clients(now: int) -> void:
	var n := 0
	while _listen.get_available_packet_count() > 0 and n < MAX_PER_FRAME:
		n += 1
		var data := _listen.get_packet()
		var ip := _listen.get_packet_ip()
		var port := _listen.get_packet_port()
		if ip == "" or port <= 0:
			continue
		var key := "%s:%d" % [ip, port]
		var s: Dictionary = _sessions.get(key, {})
		if s.is_empty():
			s = _open_session(key, ip, port)
			if s.is_empty():
				continue
		s["last_usec"] = now
		_enqueue(s, DIR_UP, data, now)


func _receive_from_host(s: Dictionary, now: int) -> void:
	var up: PacketPeerUDP = s["up"]
	var n := 0
	while up.get_available_packet_count() > 0 and n < MAX_PER_FRAME:
		n += 1
		var data := up.get_packet()
		if up.get_packet_port() != _host_port:
			continue # not from the host
		s["last_usec"] = now
		_enqueue(s, DIR_DOWN, data, now)


func _open_session(key: String, ip: String, port: int) -> Dictionary:
	var up := PacketPeerUDP.new()
	var err := up.bind(0, "127.0.0.1")
	if err != OK:
		printerr("udp_proxy: cannot open an upstream socket for %s (%s)" % [key, error_string(err)])
		return {}
	up.set_dest_address(_host_ip, _host_port)
	var index := _session_count
	_session_count += 1
	var rng_up := RandomNumberGenerator.new()
	rng_up.seed = _seed * 1000 + 2 * index
	var rng_down := RandomNumberGenerator.new()
	rng_down.seed = _seed * 1000 + 2 * index + 1
	var s := {"key": key, "ip": ip, "port": port, "index": index, "up": up, "rng": [rng_up, rng_down],
			"queue": [[], []], "free_at": [0, 0], "last_usec": Time.get_ticks_usec()}
	_sessions[key] = s
	print("udp_proxy: session %d opened for %s (upstream port %d)" % [index, key, up.get_local_port()])
	return s


## Decides the datagram's fate with the session's dice for that direction: dropped, or queued for its due time.
func _enqueue(s: Dictionary, dir: int, data: PackedByteArray, now: int) -> void:
	var rng: RandomNumberGenerator = s["rng"][dir]
	var lost := rng.randf() < _loss
	var jitter := rng.randi_range(-_jitter_usec, _jitter_usec) if _jitter_usec > 0 else 0
	if lost:
		_drop[dir] += 1
		return
	var due := now + maxi(_delay_usec + jitter, 0)
	var queue: Array = s["queue"][dir]
	if _reorder:
		# After every entry due at the same time or earlier (before = false: the comparator gets (value, entry)).
		var at := queue.bsearch_custom(due, func(a: Variant, b: Variant) -> bool: return _due_of(a) < _due_of(b), false)
		queue.insert(at, [due, data])
	else:
		due = maxi(due, int(s["free_at"][dir]))
		s["free_at"][dir] = due
		queue.append([due, data])


static func _due_of(x: Variant) -> int:
	return int((x as Array)[0]) if x is Array else int(x)


func _flush(s: Dictionary, dir: int, now: int) -> void:
	var queue: Array = s["queue"][dir]
	while not queue.is_empty() and int(queue[0][0]) <= now:
		var entry: Array = queue.pop_front()
		var data: PackedByteArray = entry[1]
		if dir == DIR_UP:
			(s["up"] as PacketPeerUDP).put_packet(data)
		else:
			_listen.set_dest_address(String(s["ip"]), int(s["port"]))
			_listen.put_packet(data)
		_fwd[dir] += 1
		_bytes[dir] += data.size()


func _stop(why: String) -> void:
	if _done:
		return
	_done = true
	print("UDP_PROXY_DONE (%s) %s" % [why, _stats_line(Time.get_ticks_usec())])


func _stats_line(now: int) -> String:
	var secs := float(now - _t0_usec) / 1000000.0
	var lost_share := func(dir: int) -> float:
		var total := _fwd[dir] + _drop[dir]
		return 100.0 * float(_drop[dir]) / float(total) if total > 0 else 0.0
	return "%.0f s, %d sessions (%d open); up %d sent %d dropped (%.1f%%) %d B; down %d sent %d dropped (%.1f%%) %d B" % [
			secs, _session_count, _sessions.size(), _fwd[DIR_UP], _drop[DIR_UP], lost_share.call(DIR_UP), _bytes[DIR_UP],
			_fwd[DIR_DOWN], _drop[DIR_DOWN], lost_share.call(DIR_DOWN), _bytes[DIR_DOWN]]


# --- arguments -------------------------------------------------------------------------------------------------------

func _parse_args() -> bool:
	var args := {}
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--"):
			var body := a.substr(2)
			var eq := body.find("=")
			if eq >= 0:
				args[body.substr(0, eq)] = body.substr(eq + 1)
			else:
				args[body] = true
	_listen_port = int(args.get("listen", 0))
	var host := String(args.get("host", ""))
	var colon := host.rfind(":")
	if colon > 0:
		_host_ip = host.substr(0, colon)
		_host_port = int(host.substr(colon + 1))
	if _listen_port < 1 or _listen_port > 65535 or _host_port < 1 or _host_port > 65535 or not _host_ip.is_valid_ip_address():
		printerr("udp_proxy: usage: -- --listen=<port> --host=<ip>:<port> [--delay-ms=N] [--jitter-ms=N] [--loss=0..1] [--seed=N] [--max-sec=N] [--quit-file=path] [--reorder]")
		return false
	_delay_usec = maxi(int(float(args.get("delay-ms", 0)) * 1000.0), 0)
	_jitter_usec = clampi(int(float(args.get("jitter-ms", 0)) * 1000.0), 0, _delay_usec)
	_loss = clampf(float(args.get("loss", 0.0)), 0.0, 1.0)
	_seed = int(args.get("seed", 1))
	_reorder = args.has("reorder")
	_max_usec = int(maxf(float(args.get("max-sec", 1800)), 1.0) * 1000000.0)
	_quit_file = String(args.get("quit-file", ""))
	_stats_usec = int(maxf(float(args.get("stats-sec", 30)), 0.0) * 1000000.0)
	_idle_usec = int(maxf(float(args.get("idle-sec", 120)), 1.0) * 1000000.0)
	return true
