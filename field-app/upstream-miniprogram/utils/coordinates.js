// WGS-84 is the storage format. Convert only at the map boundary.
// Conversion mathematics adapted from wandergis/coordtransform (MIT).
// See THIRD_PARTY_NOTICES.txt. These are approximate display conversions.
const A = 6378245
const EE = 0.00669342162296594323
const PI = Math.PI

function coordinateNumber(value) {
  if (typeof value !== 'number' && typeof value !== 'string') return null
  if (typeof value === 'string' && !/^[+-]?(?:\d+\.?\d*|\.\d+)(?:e[+-]?\d+)?$/i.test(value.trim())) return null
  const number = Number(value)
  return Number.isFinite(number) ? number : null
}

function validPoint(point) {
  if (!point) return null
  const lat = coordinateNumber(point.lat)
  const lng = coordinateNumber(point.lng)
  if (lat === null || lng === null || Math.abs(lat) > 90 || Math.abs(lng) > 180) return null
  return { lat: lat, lng: lng }
}

function outsideChina(point) {
  return point.lng < 72.004 || point.lng > 137.8347 || point.lat < 0.8293 || point.lat > 55.8271
}

function latitudeDelta(x, y) {
  let value = -100 + 2 * x + 3 * y + 0.2 * y * y + 0.1 * x * y + 0.2 * Math.sqrt(Math.abs(x))
  value += (20 * Math.sin(6 * x * PI) + 20 * Math.sin(2 * x * PI)) * 2 / 3
  value += (20 * Math.sin(y * PI) + 40 * Math.sin(y * PI / 3)) * 2 / 3
  value += (160 * Math.sin(y * PI / 12) + 320 * Math.sin(y * PI / 30)) * 2 / 3
  return value
}

function longitudeDelta(x, y) {
  let value = 300 + x + 2 * y + 0.1 * x * x + 0.1 * x * y + 0.1 * Math.sqrt(Math.abs(x))
  value += (20 * Math.sin(6 * x * PI) + 20 * Math.sin(2 * x * PI)) * 2 / 3
  value += (20 * Math.sin(x * PI) + 40 * Math.sin(x * PI / 3)) * 2 / 3
  value += (150 * Math.sin(x * PI / 12) + 300 * Math.sin(x * PI / 30)) * 2 / 3
  return value
}

function wgs84ToGcj02(input) {
  const point = validPoint(input)
  if (!point || outsideChina(point)) return point
  const radians = point.lat * PI / 180
  const magic = 1 - EE * Math.sin(radians) * Math.sin(radians)
  const root = Math.sqrt(magic)
  const lat = latitudeDelta(point.lng - 105, point.lat - 35) * 180 / ((A * (1 - EE) / (magic * root)) * PI)
  const lng = longitudeDelta(point.lng - 105, point.lat - 35) * 180 / (A / root * Math.cos(radians) * PI)
  return { lat: point.lat + lat, lng: point.lng + lng }
}

function gcj02ToWgs84(input) {
  const target = validPoint(input)
  if (!target || outsideChina(target)) return target
  let point = { lat: target.lat, lng: target.lng }
  // Invert the same forward conversion, instead of accumulating a one-pass error.
  for (let i = 0; i < 12; i++) {
    const mapped = wgs84ToGcj02(point)
    const latError = mapped.lat - target.lat
    const lngError = mapped.lng - target.lng
    point = { lat: point.lat - latError, lng: point.lng - lngError }
    if (Math.max(Math.abs(latError), Math.abs(lngError)) < 1e-7) break
  }
  return point
}

module.exports = { coordinateNumber, validPoint, wgs84ToGcj02, gcj02ToWgs84 }
