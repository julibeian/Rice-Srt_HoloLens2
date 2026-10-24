const { coordinateNumber, validPoint, gcj02ToWgs84 } = require('./coordinates')
const RECORD_LOCATION_VERSION = 2
const SOURCES = ['exif', 'device', 'manual', 'legacy']

function unavailable(reason) {
  return { status: 'unlocated', reason: reason || 'unavailable', source: null, coordSystem: 'wgs84', lat: null, lng: null, accuracy: null, acquiredAt: null }
}

function located(input, source, metadata) {
  const point = validPoint(input)
  if (!point || SOURCES.indexOf(source) < 0) return unavailable('invalid-coordinates')
  const meta = metadata || {}
  const accuracy = coordinateNumber(meta.accuracy)
  const acquiredAt = coordinateNumber(meta.acquiredAt)
  return {
    status: 'located', reason: null, source: source, coordSystem: 'wgs84',
    lat: point.lat, lng: point.lng,
    accuracy: accuracy !== null && accuracy >= 0 ? accuracy : null,
    acquiredAt: acquiredAt !== null && acquiredAt >= 0 ? acquiredAt : null
  }
}

function normalizeLocation(value) {
  if (!value || value.status !== 'located') return unavailable(value && value.reason)
  if (value.coordSystem !== 'wgs84') return unavailable('unknown-coordinate-system')
  return located(value, value.source, value)
}

function legacyLocation(value) {
  if (!value || (value.lat == null && value.lng == null)) return unavailable('no-gps')
  const point = validPoint(value)
  if (!point) return unavailable('invalid-coordinates')
  const system = value.coordSystem || 'gcj02'
  if (system !== 'wgs84' && system !== 'gcj02') return unavailable('unknown-coordinate-system')
  const source = SOURCES.indexOf(value.coordSource) >= 0 ? value.coordSource : 'legacy'
  return located(system === 'gcj02' ? gcj02ToWgs84(point) : point, source, value)
}

function locationBadge(value) {
  const location = normalizeLocation(value)
  if (location.status !== 'located') return '未定位'
  return { exif: '照片位置', device: '拍照定位', manual: '手动位置', legacy: '旧版定位' }[location.source]
}

function locationText(value) {
  const location = normalizeLocation(value)
  if (location.status === 'located') {
    const source = { exif: '照片拍摄位置', device: '拍照后获取的设备位置', manual: '手动确认的田块位置', legacy: '旧版检测时设备位置，建议核对' }[location.source]
    return source + (location.accuracy !== null ? ' · 精度约 ' + Math.ceil(location.accuracy) + ' 米' : '')
  }
  const reasons = {
    'permission-denied': '未取得位置授权，可在记录中补充位置',
    'privacy-denied': '位置使用许可不可用，可在记录中补充位置',
    timeout: '定位超时，可在记录中补充位置',
    'no-gps': '照片没有拍摄位置，可在记录中补充',
    'unsupported-format': '照片位置暂不可读取，可在记录中补充',
    'unsupported-datum': '照片坐标无法确认，可在记录中补充',
    'read-failed': '照片位置读取失败，可在记录中补充',
    'invalid-exif': '照片位置数据异常，可在记录中补充',
    'capture-expired': '未及时取得拍照位置，请手动确认田块',
    'unknown-origin': '图片选择方式不明，请手动确认田块位置'
  }
  return reasons[location.reason] || '未取得可靠位置，可在记录中补充'
}

function normalizeResult(result, fallback) {
  const value = result || {}
  let location
  if (Object.prototype.hasOwnProperty.call(value, 'location')) {
    location = normalizeLocation(value.location)
  } else if (value.lat != null || value.lng != null) {
    location = legacyLocation(value)
  } else {
    location = fallback ? normalizeLocation(fallback) : unavailable('no-gps')
  }
  return Object.assign({}, value, {
    location: location,
    lat: location.lat, lng: location.lng, coordSystem: 'wgs84', coordSource: location.source,
    locationText: locationText(location), locationBadge: locationBadge(location)
  })
}

function isLocationEligible(result) {
  // The service decides validity (including its confidence threshold). Retain
  // accepted statuses in old records, but never override an explicit rejection.
  return !!result && (result.displayStatus === 'disease' || result.displayStatus === 'healthy') &&
    result.is_valid !== false && result.predicted_class !== '其他' && result.predicted_class !== '检测失败'
}

function normalizeRecord(record) {
  const value = record || {}
  // The previous implementation stored detection-time GCJ-02 on the batch.
  // Migrate only legacy records; explicit unlocated photos must stay unlocated.
  const legacy = value.locationVersion !== RECORD_LOCATION_VERSION
    ? legacyLocation(value) : unavailable('no-gps')
  const results = (Array.isArray(value.sortedResults) ? value.sortedResults : [])
    .filter(function(result) { return result && typeof result === 'object' })
    .map(function(result, index) {
      const input = Object.assign({}, result, { imageIndex: result.imageIndex == null ? index + 1 : result.imageIndex })
      if (value.locationVersion === RECORD_LOCATION_VERSION && !Object.prototype.hasOwnProperty.call(input, 'location') && !input.coordSystem) {
        input.location = unavailable(input.lat != null || input.lng != null ? 'unknown-coordinate-system' : 'no-gps')
      }
      return normalizeResult(input,
        legacy.status === 'located' ? legacy : null)
    })
  const eligible = results.filter(isLocationEligible)
  const count = eligible.filter(function(result) { return result.location.status === 'located' }).length
  const legacyBatch = value.legacyBatchLocation ? normalizeLocation(value.legacyBatchLocation) : legacy
  const summary = value.summary || {}
  const hasAnyGps = count > 0 || (results.length === 0 && legacyBatch.status === 'located' &&
    (summary.hasDisease === true || summary.isAllHealthy === true))
  return Object.assign({}, value, {
    locationVersion: RECORD_LOCATION_VERSION,
    legacyBatchLocation: legacyBatch,
    // A batch has no unique point: its photos can belong to different fields.
    lat: null, lng: null, coordSystem: 'wgs84',
    sortedResults: results, locationCount: count, locationEligibleCount: eligible.length,
    hasAnyGps: hasAnyGps,
    isMapMarked: !!value.isMapMarked && hasAnyGps
  })
}

function recordPoints(record) {
  const normalized = normalizeRecord(record)
  const points = normalized.sortedResults.filter(function(result) { return isLocationEligible(result) && result.location.status === 'located' })
    .map(function(result, index) {
      return {
        key: String(normalized.id) + ':' + String(result.imageIndex == null ? index : result.imageIndex),
        recordId: normalized.id, imageIndex: result.imageIndex,
        name: result.predicted_class || '检测结果', status: result.displayStatus || 'unknown',
        time: normalized.time || '', location: result.location, imagePath: result.imagePath || normalized.thumbnailPath || ''
      }
    })
  if (!points.length && normalized.sortedResults.length === 0 && normalized.hasAnyGps) {
    const summary = normalized.summary || {}
    points.push({ key: String(normalized.id) + ':legacy', recordId: normalized.id, imageIndex: null,
      name: summary.diseaseNamesText || '旧版批次位置', status: summary.hasDisease ? 'disease' : (summary.isAllHealthy ? 'healthy' : 'unknown'),
      time: normalized.time || '', location: normalized.legacyBatchLocation, imagePath: normalized.thumbnailPath || '' })
  }
  return points
}

module.exports = { RECORD_LOCATION_VERSION, unavailable, located, normalizeLocation, legacyLocation,
  locationBadge, locationText, normalizeResult, isLocationEligible, normalizeRecord, recordPoints }
