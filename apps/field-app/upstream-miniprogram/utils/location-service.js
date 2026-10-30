const { inspectGps } = require('./gps-extractor')
const { coordinateNumber, gcj02ToWgs84, wgs84ToGcj02 } = require('./coordinates')
const { unavailable, located } = require('./location')
const MAX_METADATA_BYTES = 512 * 1024
const DEVICE_TIMEOUT_MS = 8000
const FILE_TIMEOUT_MS = 3000
const CAPTURE_WINDOW_MS = 60000

function errorReason(error) {
  const message = String(error && error.errMsg || '').toLowerCase()
  if (/privacy/.test(message)) return 'privacy-denied'
  if (/auth deny|auth denied|authorize|permission|unauthorized/.test(message)) return 'permission-denied'
  if (/cancel/.test(message)) return 'cancelled'
  if (/timeout|time out/.test(message)) return 'timeout'
  return 'unavailable'
}

function call(api, method, options, timeout) {
  return new Promise(function(resolve) {
    let finished = false
    let timer
    function done(result) {
      if (finished) return
      finished = true
      clearTimeout(timer)
      resolve(result)
    }
    if (timeout) timer = setTimeout(function() { done({ ok: false, reason: 'timeout' }) }, timeout)
    if (!api || typeof api[method] !== 'function') return done({ ok: false, reason: 'unavailable' })
    try {
      api[method](Object.assign({}, options, {
        success: function(value) { done({ ok: true, value: value }) },
        fail: function(error) { done({ ok: false, reason: errorReason(error) }) }
      }))
    } catch (error) { done({ ok: false, reason: errorReason(error) }) }
  })
}

async function getDeviceLocation(api, options) {
  const timeout = options && options.timeoutMs || DEVICE_TIMEOUT_MS
  const started = Date.now()
  const setting = await call(api, 'getSetting', {}, Math.min(2000, timeout))
  if (setting.ok && setting.value && setting.value.authSetting && setting.value.authSetting['scope.userLocation'] === false) {
    return unavailable('permission-denied')
  }
  const remaining = timeout - (Date.now() - started)
  if (remaining <= 0) return unavailable('timeout')
  const result = await call(api, 'getLocation', { type: 'wgs84' }, remaining)
  if (!result.ok) return unavailable(result.reason)
  if (!result.value) return unavailable('invalid-coordinates')
  return located({ lat: result.value.latitude, lng: result.value.longitude }, 'device', {
    accuracy: result.value.accuracy, acquiredAt: Date.now()
  })
}

async function readPhotoLocation(image, api) {
  let fs
  try { fs = api.getFileSystemManager() } catch (error) { return { location: unavailable('read-failed'), format: 'unknown' } }
  // getFileInfo avoids asking readFile to read past EOF. No encoding => ArrayBuffer.
  const info = await call(fs, 'getFileInfo', { filePath: image.path }, FILE_TIMEOUT_MS)
  if (!info.ok || !info.value || !info.value.size) return { location: unavailable('read-failed'), format: 'unknown' }
  const result = await call(fs, 'readFile', { filePath: image.path, position: 0,
    length: Math.min(info.value.size, MAX_METADATA_BYTES) }, FILE_TIMEOUT_MS)
  if (!result.ok || !result.value) return { location: unavailable('read-failed'), format: 'unknown' }
  const inspected = inspectGps(result.value.data)
  return {
    location: inspected.status === 'located'
      ? located(inspected, 'exif', { acquiredAt: Date.now() }) : unavailable(inspected.reason),
    format: inspected.format
  }
}

async function resolveImageLocations(images, api) {
  let devicePromise
  return Promise.all(images.map(async function(image) {
    const photo = await readPhotoLocation(image, api)
    let location = photo.location
    if (location.status !== 'located' && image.origin === 'camera') {
      if (!image.selectedAt || Date.now() - image.selectedAt > CAPTURE_WINDOW_MS) {
        return Object.assign({}, image, { location: unavailable('capture-expired'), imageFormat: photo.format })
      }
      // Request only while processing a freshly captured photo; never at detection.
      if (!devicePromise) devicePromise = getDeviceLocation(api)
      location = await devicePromise
      if (location.status === 'located' && (!image.selectedAt || location.acquiredAt - image.selectedAt > CAPTURE_WINDOW_MS)) {
        location = unavailable('capture-expired')
      }
    } else if (location.status !== 'located' && image.origin !== 'album') {
      location = unavailable('unknown-origin')
    }
    return Object.assign({}, image, { location: location, imageFormat: photo.format })
  }))
}

async function chooseManualLocation(api, currentLocation) {
  // This is interactive. Do not timeout while the user is selecting a field.
  const point = currentLocation && currentLocation.status === 'located' ? wgs84ToGcj02(currentLocation) : null
  const result = await call(api, 'chooseLocation', point ? { latitude: point.lat, longitude: point.lng } : {}, 0)
  if (!result.ok) return unavailable(result.reason)
  if (!result.value) return unavailable('invalid-coordinates')
  return located(gcj02ToWgs84({ lat: result.value.latitude, lng: result.value.longitude }), 'manual', { acquiredAt: Date.now() })
}

function locationFromManualCoordinates(input, system) {
  const lng = coordinateNumber(input && input.lng)
  const lat = coordinateNumber(input && input.lat)
  if (lng === null) throw new Error('请输入有效经度，例如 118.761116')
  if (Math.abs(lng) > 180) throw new Error('经度范围为 -180 到 180')
  if (lat === null) throw new Error('请输入有效纬度，例如 32.035957')
  if (Math.abs(lat) > 90) throw new Error('纬度范围为 -90 到 90')
  if (system !== 'wgs84' && system !== 'gcj02') throw new Error('请选择坐标类型')
  const point = { lat: lat, lng: lng }
  return located(system === 'gcj02' ? gcj02ToWgs84(point) : point, 'manual', { acquiredAt: Date.now() })
}

function showPermissionGuide(api) {
  api.showModal({
    title: '位置授权未开启',
    content: '识别可以继续。开启位置授权后，新拍照片可保存设备位置；已有照片请在检测记录中手动补充田块位置。',
    confirmText: '打开设置', cancelText: '暂不开启',
    success: function(result) {
      if (result.confirm) api.openSetting({ fail: function() { api.showToast({ title: '打开设置失败，请稍后重试', icon: 'none' }) } })
    }
  })
}

module.exports = { getDeviceLocation, readPhotoLocation, resolveImageLocations, chooseManualLocation,
  locationFromManualCoordinates, showPermissionGuide, MAX_METADATA_BYTES }
