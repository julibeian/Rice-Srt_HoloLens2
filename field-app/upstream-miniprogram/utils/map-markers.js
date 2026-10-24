const { recordPoints, locationText } = require('./location')
const { wgs84ToGcj02 } = require('./coordinates')

function stableId(key) {
  let hash = 2166136261
  for (let i = 0; i < key.length; i++) hash = Math.imul(hash ^ key.charCodeAt(i), 16777619)
  return hash & 0x7FFFFFFF
}

function buildMarkers(records, filter) {
  const points = []
  records.filter(function(record) { return record.isMapMarked }).forEach(function(record) {
    recordPoints(record).forEach(function(point) { points.push(point) })
  })
  const used = {}
  // Assign identities before filtering, so callbacks keep the same photo identity.
  const all = points.map(function(point) {
    const coordinate = wgs84ToGcj02(point.location)
    let id = stableId(point.key)
    while (used[id]) id = (id + 1) & 0x7FFFFFFF
    used[id] = true
    const disease = point.status === 'disease'
    const healthy = point.status === 'healthy'
    const label = point.imageIndex == null ? '旧版批次' : '图片 ' + point.imageIndex
    return {
      recordId: point.recordId, status: point.status,
      photo: { key: point.key, markerId: id, recordId: point.recordId, imageIndex: point.imageIndex,
        imageLabel: label, imagePath: point.imagePath, name: point.name, status: point.status,
        time: point.time, locationText: locationText(point.location), latitude: coordinate.lat, longitude: coordinate.lng },
      marker: {
        id: id, latitude: coordinate.lat, longitude: coordinate.lng,
        width: 30, height: 30, iconPath: '/assets/icons/map-pin-green.png',
        callout: {
          content: label + ' · ' + point.name + '\n' + point.time + '\n' + locationText(point.location),
          color: disease ? '#9F3F35' : (healthy ? '#176B3A' : '#626F67'), fontSize: 12, borderRadius: 9,
          borderWidth: 1, borderColor: disease ? '#D99A8F' : (healthy ? '#9DC8A7' : '#A7AFA8'),
          bgColor: disease ? '#FFF1EC' : (healthy ? '#EDF6EA' : '#F0F1ED'), padding: 8, display: 'BYCLICK', textAlign: 'left'
        }
      }
    }
  })
  const visible = all.filter(function(item) { return filter !== 'disease' && filter !== 'healthy' || item.status === filter })
  const recordIds = {}
  visible.forEach(function(item) { recordIds[item.marker.id] = item.recordId })
  return { markers: visible.map(function(item) { return item.marker }), photos: visible.map(function(item) { return item.photo }), recordIds: recordIds,
    markedCount: all.length, diseaseCount: all.filter(function(item) { return item.status === 'disease' }).length }
}

module.exports = { buildMarkers }
