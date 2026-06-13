@tool
extends RefCounted

## Pure GDScript GIF89a decoder — FIRST FRAME ONLY.
##
## Trying to animate GIFs across all godotshaders.com previews was a losing
## game (disposal-method conventions diverge between encoders, browsers ignore
## the spec for disposal=2, etc.). moongdevstudio/AssetPlus solves the same
## problem by decoding only the first frame and showing it as a static
## thumbnail; we do the same. The ▶ badge on the card flags it as animated;
## "Watch Video" in the preview dialog opens the real GIF in a browser.
##
## Usage: var frames = GIFDecoder.new().decode(bytes)
## Returns Array of Dictionary: { image: Image, delay_ms: int }
## (delay_ms is kept for API compatibility but the GifPlayer ignores it.)

const _EXT := 0x21
const _IMG := 0x2C
const _END := 0x3B
const _GCE := 0xF9  # Graphic Control Extension label

var _d: PackedByteArray
var _p: int
var _w: int
var _h: int
var _gct: PackedByteArray  # raw RGB triples
var _trans_idx: int = -1
var _delay_ms: int = 100


func decode(data: PackedByteArray) -> Array:
	_d = data
	_p = 0
	if not _hdr() or not _lsd():
		return []

	# Walk blocks until the first Image Descriptor. We honor GCE blocks before
	# the first IMG so transparency / delay come through, but otherwise we just
	# skip extensions.
	while _p < _d.size():
		var b: int = _d[_p]; _p += 1
		if b == _IMG:
			var f = _frame()
			if f.is_empty(): return []
			return [f]
		elif b == _EXT:
			_ext()
		elif b == _END:
			break
		else:
			break
	return []


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
	return true


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


# ── Extension block (we only care about GCE for transparency / delay) ───────

func _ext() -> void:
	if _p >= _d.size(): return
	var lbl: int = _d[_p]; _p += 1
	if lbl == _GCE:
		var bsz: int = _d[_p]; _p += 1
		if bsz == 4 and _p + 4 <= _d.size():
			var pk: int = _d[_p]; _p += 1
			_delay_ms = _u16() * 10
			if _delay_ms == 0: _delay_ms = 80
			_trans_idx = _d[_p] if (pk & 0x01) else -1
			_p += 2  # transparent index + block terminator
	else:
		_skip_subs()


# ── Image frame ───────────────────────────────────────────────────────────────

func _frame() -> Dictionary:
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

	# Single-frame buffer initialised to transparent. We composite directly into
	# it — no separate canvas / prev_canvas / disposal handling.
	var px := PackedByteArray()
	px.resize(_w * _h * 4)
	# fill(0) leaves everything transparent black; the GifPlayer's solid-black
	# panel renders behind so the user sees black where the frame doesn't draw.

	var i := 0
	for y in range(fh):
		for x in range(fw):
			if i >= idx.size(): i += 1; continue
			var ci: int = idx[i]; i += 1
			if ci == _trans_idx: continue
			if ci >= ct_entries: continue
			var dst_x: int = left + x
			var dst_y: int = top + y
			if dst_x >= _w or dst_y >= _h: continue
			var off: int = (dst_y * _w + dst_x) * 4
			var pal_off: int = ci * 3
			px[off]   = ct[pal_off]
			px[off+1] = ct[pal_off+1]
			px[off+2] = ct[pal_off+2]
			px[off+3] = 255

	var img := Image.create_from_data(_w, _h, false, Image.FORMAT_RGBA8, px)
	return {"image": img, "delay_ms": _delay_ms}


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
