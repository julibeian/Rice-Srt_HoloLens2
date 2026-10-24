// Bounded JPEG/Exif reader. All TIFF offsets are relative to their APP1 segment.
// inspectGps distinguishes missing metadata, unsupported formats and corruption.
const { validPoint } = require('./coordinates')

function failure(reason, format) {
  return { status: 'unlocated', reason: reason, format: format || 'unknown', lat: null, lng: null }
}

function ascii(view, offset, count) {
  let text = ''
  for (let i = 0; i < count; i++) text += String.fromCharCode(view.getUint8(offset + i))
  return text
}

function parseExif(view, start, end) {
  function check(offset, length) {
    if (!Number.isSafeInteger(offset) || length < 0 || offset < start || offset + length > end) throw new Error('invalid-exif')
  }
  check(start, 8)
  const order = ascii(view, start, 2)
  if (order !== 'II' && order !== 'MM') throw new Error('invalid-exif')
  const little = order === 'II'
  function uint16(offset) { check(offset, 2); return view.getUint16(offset, little) }
  function uint32(offset) { check(offset, 4); return view.getUint32(offset, little) }
  if (uint16(start + 2) !== 42) throw new Error('invalid-exif')

  function readIfd(relativeOffset) {
    if (relativeOffset < 8) throw new Error('invalid-exif')
    const offset = start + relativeOffset
    const count = uint16(offset)
    check(offset, 2 + count * 12 + 4)
    const entries = {}
    for (let i = 0; i < count; i++) {
      const position = offset + 2 + i * 12
      const tag = uint16(position)
      if (entries[tag]) throw new Error('invalid-exif')
      entries[tag] = { type: uint16(position + 2), count: uint32(position + 4), valuePosition: position + 8 }
    }
    return entries
  }

  function dataOffset(entry, bytes) {
    const offset = bytes <= 4 ? entry.valuePosition : start + uint32(entry.valuePosition)
    check(offset, bytes)
    return offset
  }

  function readAscii(entry) {
    if (!entry || entry.type !== 2 || entry.count < 1 || entry.count > 128) throw new Error('invalid-exif')
    const offset = dataOffset(entry, entry.count)
    return ascii(view, offset, entry.count).split('\0')[0]
  }

  function readDegrees(entry, ref, allowedRefs, maximum) {
    if (!entry || entry.type !== 5 || entry.count !== 3 || allowedRefs.indexOf(ref) < 0) throw new Error('invalid-exif')
    const offset = dataOffset(entry, 24)
    const parts = []
    for (let i = 0; i < 3; i++) {
      const denominator = uint32(offset + i * 8 + 4)
      if (denominator === 0) throw new Error('invalid-exif')
      parts.push(uint32(offset + i * 8) / denominator)
    }
    if (parts[0] > maximum || parts[1] >= 60 || parts[2] >= 60) throw new Error('invalid-exif')
    const degrees = parts[0] + parts[1] / 60 + parts[2] / 3600
    if (degrees > maximum) throw new Error('invalid-exif')
    return ref === 'S' || ref === 'W' ? -degrees : degrees
  }

  const root = readIfd(uint32(start + 4))
  const pointer = root[0x8825]
  if (!pointer) return failure('no-gps', 'jpeg')
  if (pointer.type !== 4 || pointer.count !== 1) throw new Error('invalid-exif')
  const gps = readIfd(uint32(pointer.valuePosition))
  if (!gps[2] && !gps[4]) return failure('no-gps', 'jpeg')
  if (gps[0x12] && readAscii(gps[0x12]).trim().toUpperCase().replace(/[\s-]/g, '') !== 'WGS84') {
    throw new Error('unsupported-datum')
  }
  const point = validPoint({
    lat: readDegrees(gps[2], readAscii(gps[1]), 'NS', 90),
    lng: readDegrees(gps[4], readAscii(gps[3]), 'EW', 180)
  })
  if (!point) throw new Error('invalid-exif')
  return { status: 'located', reason: null, format: 'jpeg', lat: point.lat, lng: point.lng }
}

function inspectGps(buffer) {
  let format = 'unknown'
  try {
    const view = ArrayBuffer.isView(buffer)
      ? new DataView(buffer.buffer, buffer.byteOffset, buffer.byteLength) : new DataView(buffer)
    const length = view.byteLength
    if (length < 2) return failure('invalid-exif')
    if (view.getUint16(0) !== 0xFFD8) {
      if (length >= 12 && ascii(view, 4, 4) === 'ftyp') {
        const brands = ascii(view, 8, Math.min(length - 8, 64))
        if (/heic|heix|hevc|hevx|heim|heis|mif1|msf1/.test(brands)) format = 'heif'
      } else if (length >= 8 && view.getUint32(0) === 0x89504E47) format = 'png'
      else if (length >= 12 && ascii(view, 0, 4) === 'RIFF' && ascii(view, 8, 4) === 'WEBP') format = 'webp'
      return failure('unsupported-format', format)
    }
    format = 'jpeg'
    let offset = 2
    while (offset + 1 < length) {
      if (view.getUint8(offset) !== 0xFF) return failure('invalid-exif', format)
      while (offset < length && view.getUint8(offset) === 0xFF) offset++
      if (offset >= length) return failure('invalid-exif', format)
      const marker = view.getUint8(offset++)
      // Metadata precedes scan data. Never search the compressed image for APP1.
      if (marker === 0xDA || marker === 0xD9) return failure('no-gps', format)
      if (marker === 0x01 || (marker >= 0xD0 && marker <= 0xD8)) continue
      if (marker === 0 || offset + 2 > length) return failure('invalid-exif', format)
      const size = view.getUint16(offset)
      const end = offset + size
      if (size < 2 || end > length) return failure('invalid-exif', format)
      if (marker === 0xE1 && size >= 16 && ascii(view, offset + 2, 6) === 'Exif\0\0') {
        const result = parseExif(view, offset + 8, end)
        if (result.status === 'located') return result
      }
      offset = end
    }
    return failure('no-gps', format)
  } catch (error) {
    return failure(error.message === 'unsupported-datum' ? 'unsupported-datum' : 'invalid-exif', format)
  }
}

function extractGps(buffer) {
  const result = inspectGps(buffer)
  return result.status === 'located' ? { lat: result.lat, lng: result.lng } : null
}

module.exports = { extractGps, inspectGps }
