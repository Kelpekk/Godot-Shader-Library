@tool
extends RefCounted

## Pure GDScript GIF89a decoder.
##
## Entry points:
##   decode(bytes)                 -> Array with ONLY the first composited frame
##                                    (cheap; the static thumbnail on cards).
##   decode_all(bytes)             -> Array with up to MAX_ANIM_FRAMES frames.
##   decode_streaming(bytes, n, cb)-> decodes up to n frames, invoking cb per
##                                    frame as it's produced (progressive
##                                    playback: the UI starts animating with the
##                                    first couple of frames while the rest keep
##                                    arriving). Runs on the caller's thread.
##
## Each frame is { image: Image, delay_ms: int } — a full logical-screen-sized
## RGBA frame already composited over the running canvas, so the player just
## swaps textures.
##
## Disposal handling is the part that historically broke animation: encoders
## and browsers disagree on disposal=2. We follow the browser convention —
## disposal 2 clears the frame's rect to TRANSPARENT (not the background color),
## disposal 3 restores the canvas snapshot from before the frame. That matches
## how these GIFs look on godotshaders.com.

const _EXT := 0x21
const _IMG := 0x2C
const _END := 0x3B
const _GCE := 0xF9  # Graphic Control Extension label

# Hard cap on decoded frames. Bounds worst-case decode time AND memory for very
# long GIFs; they simply loop the first MAX_ANIM_FRAMES frames.
const MAX_ANIM_FRAMES := 60

var _d: PackedByteArray
var _p: int
var _w: int
var _h: int
var _gct: PackedByteArray  # raw RGB triples

# Emit target: either an array we collect into, or a per-frame callback.
var _out_frames: Array = []
var _on_frame: Callable = Callable()
var _max_frames: int = 1


func decode(data: PackedByteArray) -> Array:
	return _run(data, 1, Callable())


func decode_all(data: PackedByteArray) -> Array:
	return _run(data, MAX_ANIM_FRAMES, Callable())


func decode_streaming(data: PackedByteArray, max_frames: int, on_frame: Callable) -> void:
	_run(data, max_frames, on_frame)


func _run(data: PackedByteArray, max_frames: int, on_frame: Callable) -> Array:
	_out_frames = []
	_on_frame = on_frame
	_max_frames = maxi(1, max_frames)
	_decode(data)
	return _out_frames


func _emit(img: Image, delay_ms: int) -> void:
	var fr := {"image": img, "delay_ms": delay_ms}
	if _on_frame.is_valid():
		_on_frame.call(fr)
	else:
		_out_frames.append(fr)


func _decode(data: PackedByteArray) -> void:
	_d = data
	_p = 0
	if not _hdr() or not _lsd():
		return

	var emitted: int = 0
	# Running canvas the frames composite onto (persists across frames).
	var canvas := PackedByteArray()
	canvas.resize(_w * _h * 4)  # zero-filled == transparent

	# Pending Graphic Control Extension state for the NEXT image block.
	var g_delay: int = 100
	var g_trans: int = -1
	var g_disposal: int = 0

	while _p < _d.size():
		var b: int = _d[_p]; _p += 1
		if b == _IMG:
			var fr = _read_frame_indices()
			if fr.is_empty():
				return  # corrupt — stop with whatever we've emitted
			var disposal: int = g_disposal
			# Snapshot BEFORE compositing, so disposal=3 can restore it.
			var snapshot: PackedByteArray
			if disposal == 3:
				snapshot = canvas.duplicate()

			_blit(canvas, fr, g_trans)

			var img := Image.create_from_data(_w, _h, false, Image.FORMAT_RGBA8, canvas.duplicate())
			_emit(img, g_delay)
			emitted += 1

			if emitted >= _max_frames:
				return

			# Apply THIS frame's disposal to prepare the canvas for the next one.
			match disposal:
				2:  # restore to background -> browsers treat as clear-to-transparent
					_clear_rect(canvas, fr["left"], fr["top"], fr["fw"], fr["fh"])
				3:  # restore to previous
					canvas = snapshot
				_:  # 0 / 1: leave the canvas as-is
					pass

			# Reset pending GCE for the next frame.
			g_delay = 100; g_trans = -1; g_disposal = 0
		elif b == _EXT:
			if _p >= _d.size(): break
			var lbl: int = _d[_p]; _p += 1
			if lbl == _GCE:
				var bsz: int = _d[_p]; _p += 1
				if bsz == 4 and _p + 5 <= _d.size():
					var pk: int = _d[_p]; _p += 1
					g_disposal = (pk >> 2) & 0x07
					g_delay = _u16() * 10
					if g_delay == 0: g_delay = 80
					g_trans = _d[_p] if (pk & 0x01) else -1
					_p += 2  # transparent index + block terminator
				else:
					_skip_subs()
			else:
				_skip_subs()
		elif b == _END:
			break
		else:
			break


# ── Header / Logical Screen Descriptor ────────────────────────────────────────

func _hdr() -> bool:
	if _d.size() < 6: return false
	var ok = char(_d[0]) == "G" and char(_d[1]) == "I" and char(_d[2]) == "F"
	_p = 6
	return ok


func _lsd() -> bool:
	if _p + 7 > _d.size(): return false
	_w = _u16(); _h = _u16()
	var pk: int = _d[_p]; _p += 1
	_p += 2  # bg color index + pixel aspect ratio (we don't use them)
	if pk & 0x80:
		var gct_sz: int = 2 << (pk & 0x07)
		_gct = _read_palette(gct_sz)
	else:
		_gct = PackedByteArray()
	return _w > 0 and _h > 0


func _read_palette(n: int) -> PackedByteArray:
	var out := PackedByteArray()
	out.resize(n * 3)
	for i in range(n):
		if _p + 3 > _d.size(): break
		out[i*3]   = _d[_p]
		out[i*3+1] = _d[_p+1]
		out[i*3+2] = _d[_p+2]
		_p += 3
	return out


# ── Image frame: read descriptor + decode palette indices ─────────────────────
# Returns { idx, left, top, fw, fh, ct, ct_entries } or {} on failure.

func _read_frame_indices() -> Dictionary:
	if _p + 9 > _d.size(): return {}

	var left: int = _u16(); var top: int = _u16()
	var fw: int   = _u16(); var fh: int  = _u16()
	var pk: int   = _d[_p]; _p += 1

	var interlaced: bool = (pk & 0x40) != 0
	var lct_sz: int = 2 << (pk & 0x07)
	var ct: PackedByteArray = _read_palette(lct_sz) if (pk & 0x80) else _gct
	var ct_entries: int = ct.size() / 3

	if _p >= _d.size(): return {}
	var mcs: int = _d[_p]; _p += 1
	var raw: PackedByteArray = _subs()

	var idx: PackedByteArray = _lzw(raw, mcs)
	if interlaced: idx = _deinterlace(idx, fw, fh)

	return {
		"idx": idx, "left": left, "top": top, "fw": fw, "fh": fh,
		"ct": ct, "ct_entries": ct_entries,
	}


# Composite a frame's palette indices onto the running canvas at its offset,
# skipping the transparent index so earlier canvas content shows through.
func _blit(canvas: PackedByteArray, fr: Dictionary, trans_idx: int) -> void:
	var idx: PackedByteArray = fr["idx"]
	var ct: PackedByteArray = fr["ct"]
	var ct_entries: int = fr["ct_entries"]
	var left: int = fr["left"]; var top: int = fr["top"]
	var fw: int = fr["fw"]; var fh: int = fr["fh"]

	var idx_n: int = idx.size()
	var i := 0
	for y in range(fh):
		var dst_y: int = top + y
		if dst_y >= _h:
			break
		var row_off: int = dst_y * _w * 4  # hoisted out of the x loop
		for x in range(fw):
			if i >= idx_n:
				return
			var ci: int = idx[i]; i += 1
			if ci == trans_idx: continue
			if ci >= ct_entries: continue
			var dst_x: int = left + x
			if dst_x >= _w: continue
			var off: int = row_off + dst_x * 4
			var pal_off: int = ci * 3
			canvas[off]   = ct[pal_off]
			canvas[off+1] = ct[pal_off+1]
			canvas[off+2] = ct[pal_off+2]
			canvas[off+3] = 255


# Clear a rectangle of the canvas back to transparent (disposal method 2).
func _clear_rect(canvas: PackedByteArray, left: int, top: int, fw: int, fh: int) -> void:
	for y in range(fh):
		var dst_y: int = top + y
		if dst_y >= _h: break
		for x in range(fw):
			var dst_x: int = left + x
			if dst_x >= _w: continue
			var off: int = (dst_y * _w + dst_x) * 4
			canvas[off] = 0; canvas[off+1] = 0; canvas[off+2] = 0; canvas[off+3] = 0


# ── LZW decompressor ──────────────────────────────────────────────────────────

func _lzw(data: PackedByteArray, mcs: int) -> PackedByteArray:
	var result := PackedByteArray()
	if data.is_empty() or mcs < 2 or mcs > 11: return result

	var clear := 1 << mcs
	var eoi   := clear + 1

	# Initialize code table: entries 0..clear-1 are single-byte palette indices
	var table: Array = []
	for i in range(clear):
		var e := PackedByteArray(); e.append(i); table.append(e)
	table.append(PackedByteArray())  # clear slot
	table.append(PackedByteArray())  # eoi slot

	var cs  := mcs + 1   # current code size in bits
	var di  := 0         # byte index into data
	var bb  := 0         # bit buffer
	var bc  := 0         # bits in buffer
	var prev := -1
	var inited := false

	while true:
		# Refill bit buffer
		while bc < cs:
			if di >= data.size(): return result
			bb |= data[di] << bc; bc += 8; di += 1

		var code: int = bb & ((1 << cs) - 1)
		bb >>= cs; bc -= cs

		if code == clear:
			table.resize(eoi + 1)
			cs = mcs + 1; prev = -1; inited = false
			continue

		if code == eoi: break

		if not inited:
			if code < table.size():
				result.append_array(table[code] as PackedByteArray)
				prev = code; inited = true
			continue

		var entry: PackedByteArray
		if code < table.size():
			entry = table[code] as PackedByteArray
		elif code == table.size() and prev >= 0:
			# KwKwK case: code not yet in table
			var pe: PackedByteArray = table[prev]
			entry = pe.duplicate(); entry.append(pe[0])
		else:
			break  # corrupt stream

		result.append_array(entry)

		if table.size() < 4096 and prev >= 0:
			var ne: PackedByteArray = (table[prev] as PackedByteArray).duplicate(); ne.append(entry[0])
			table.append(ne)

		prev = code
		# Standard GIF LZW convention: after appending, if next_code reaches
		# 2^cs, bump cs. Using `>` here loses sync with the encoder.
		if table.size() >= (1 << cs) and cs < 12:
			cs += 1

	return result


# ── Interlace de-interlacer ───────────────────────────────────────────────────

func _deinterlace(data: PackedByteArray, w: int, h: int) -> PackedByteArray:
	var out := PackedByteArray(); out.resize(data.size())
	# GIF interlace passes: [start_row, step]
	var passes := [[0, 8], [4, 8], [2, 4], [1, 2]]
	var src_row := 0
	for pa in passes:
		var y: int = pa[0]
		while y < h:
			for x in range(w):
				var si := src_row * w + x
				var di2 := y * w + x
				if si < data.size() and di2 < out.size():
					out[di2] = data[si]
			src_row += 1; y += pa[1]
	return out


# ── Sub-block helpers ─────────────────────────────────────────────────────────

func _subs() -> PackedByteArray:
	var out := PackedByteArray()
	while _p < _d.size():
		var sz: int = _d[_p]; _p += 1
		if sz == 0: break
		if _p + sz > _d.size(): break
		out.append_array(_d.slice(_p, _p + sz))
		_p += sz
	return out


func _skip_subs() -> void:
	while _p < _d.size():
		var sz: int = _d[_p]; _p += 1
		if sz == 0: break
		_p += mini(sz, _d.size() - _p)


func _u16() -> int:
	if _p + 2 > _d.size(): return 0
	var v: int = _d[_p] | (_d[_p+1] << 8); _p += 2; return v
