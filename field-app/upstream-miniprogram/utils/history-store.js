const { RECORD_LOCATION_VERSION, normalizeRecord, normalizeLocation, isLocationEligible } = require('./location')
const HISTORY_KEY = 'rice_history_list'
const HISTORY_MAX = 15
let clearRevision = 0

function load(api) {
  const list = api.getStorageSync(HISTORY_KEY)
  if (list === '' || list == null) return []
  if (!Array.isArray(list)) throw new Error('历史记录存储格式异常')
  return list.filter(function(record) { return record && typeof record === 'object' && record.id != null }).map(normalizeRecord)
}

function removeFiles(records, api) {
  if (!records.length || !api.env || !api.env.USER_DATA_PATH) return
  let fs
  try { fs = api.getFileSystemManager() } catch (error) { return }
  const root = api.env.USER_DATA_PATH.replace(/\/$/, '') + '/rice_'
  records.forEach(function(record) {
    const paths = Array.isArray(record.permanentPaths) ? record.permanentPaths : []
    paths.forEach(function(file) {
      // Clean up only files owned by this feature, never arbitrary legacy paths.
      if (typeof file === 'string' && file.indexOf(root) === 0 && file.indexOf('..') < 0) {
        try { fs.unlinkSync(file) } catch (error) { /* Already removed or still in use. */ }
      }
    })
  })
}

function append(record, api, expectedRevision) {
  // A save started before deletion must not bring cleared records back.
  if (expectedRevision != null && expectedRevision !== clearRevision) {
    removeFiles([record], api)
    return false
  }
  const list = load(api)
  if (list.some(function(item) { return String(item.id) === String(record.id) })) throw new Error('记录标识重复')
  list.push(normalizeRecord(record))
  list.sort(function(a, b) { return a.id - b.id })
  const removed = list.length > HISTORY_MAX ? list.splice(0, list.length - HISTORY_MAX) : []
  // Commit metadata first; failed storage writes must not delete earlier photos.
  api.setStorageSync(HISTORY_KEY, list)
  removeFiles(removed, api)
  return true
}

function update(id, transform, api) {
  const list = load(api)
  const index = list.findIndex(function(record) { return String(record.id) === String(id) })
  if (index < 0) throw new Error('记录已不存在')
  list[index] = normalizeRecord(transform(list[index]))
  api.setStorageSync(HISTORY_KEY, list)
  return list[index]
}

function toggleMapMark(id, api) {
  return update(id, function(record) {
    if (!record.isMapMarked && !record.hasAnyGps) throw new Error('请先补充田块位置，再标记到地图')
    return Object.assign({}, record, { isMapMarked: !record.isMapMarked })
  }, api)
}

function setImageLocation(id, imageIndex, value, api) {
  const location = normalizeLocation(value)
  if (location.status !== 'located') throw new Error('所选位置无效')
  return update(id, function(record) {
    let found = false
    const results = record.sortedResults.map(function(result) {
      if (String(result.imageIndex) !== String(imageIndex)) return result
      if (!isLocationEligible(result)) throw new Error('该照片未通过识别，请重拍后再补位置')
      found = true
      return Object.assign({}, result, { location: location })
    })
    if (!found) throw new Error('照片已不存在')
    return Object.assign({}, record, { locationVersion: RECORD_LOCATION_VERSION, sortedResults: results })
  }, api)
}

function removeSelected(ids, api) {
  if (!Array.isArray(ids) || !ids.length) return 0
  const selected = new Set(ids.map(String))
  const list = load(api)
  const removed = list.filter(function(record) { return selected.has(String(record.id)) })
  if (!removed.length) return 0
  const kept = list.filter(function(record) { return !selected.has(String(record.id)) })
  // Commit first and preserve a file if a retained legacy record also references it.
  api.setStorageSync(HISTORY_KEY, kept)
  const retainedPaths = new Set()
  kept.forEach(function(record) {
    const paths = Array.isArray(record.permanentPaths) ? record.permanentPaths : []
    paths.forEach(function(file) { retainedPaths.add(file) })
    retainedPaths.add(record.thumbnailPath)
    ;(record.sortedResults || []).forEach(function(result) { retainedPaths.add(result.imagePath) })
  })
  removeFiles(removed.map(function(record) {
    const paths = Array.isArray(record.permanentPaths) ? record.permanentPaths : []
    return Object.assign({}, record, { permanentPaths: paths.filter(function(file) { return !retainedPaths.has(file) }) })
  }), api)
  // Selective deletion does not cancel an unrelated new detection or pending save.
  return removed.length
}

function clear(api) {
  // Deletion must remain available even when the record index is malformed.
  const stored = api.getStorageSync(HISTORY_KEY)
  const records = (Array.isArray(stored) ? stored : [stored])
    .filter(function(record) { return record && typeof record === 'object' })
  api.removeStorageSync(HISTORY_KEY)
  clearRevision++
  removeFiles(records, api)
  // A photo copy can outlive a failed metadata commit. Also remove these owned
  // files, while preserving other files and refusing path components.
  try {
    const root = api.env.USER_DATA_PATH.replace(/\/$/, '')
    const fs = api.getFileSystemManager()
    const names = fs.readdirSync(root)
    names.forEach(function(name) {
      if (typeof name !== 'string' || !/^rice_\d+_\d+\.(?:jpe?g|png|webp|hei[cf])$/i.test(name)) return
      try { fs.unlinkSync(root + '/' + name) } catch (error) { /* A later clear can retry. */ }
    })
  } catch (error) { /* Metadata deletion still succeeds if file access is unavailable. */ }
}

function revision() { return clearRevision }

module.exports = { HISTORY_KEY, HISTORY_MAX, load, append, toggleMapMark, setImageLocation, removeSelected, clear, revision }
