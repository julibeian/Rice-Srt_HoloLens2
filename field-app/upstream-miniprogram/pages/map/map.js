const historyStore = require('../../utils/history-store')
const { buildMarkers } = require('../../utils/map-markers')
const { wgs84ToGcj02 } = require('../../utils/coordinates')
const { getDeviceLocation, showPermissionGuide } = require('../../utils/location-service')
const { headerLayout } = require('../../utils/header-layout')

Page({
  data: {
    longitude: 116.397428, latitude: 39.90923,
    markers: [], activeFilter: 'all', markedCount: 0, diseaseCount: 0,
    showLocation: false, locating: false, mapError: '', scale: 14, mapType: 'standard',
    headerTopInset: 30, headerNavHeight: 32, headerRightInset: 112,
    showPointList: false, pointListTitle: '', mapPhotos: []
  },

  onLoad() {
    this._unloaded = false
    this._mapRevision = 0
    this.setData(headerLayout(wx))
  },
  onReady() { this._mapReady = true; this._fitMarkers() },
  onUnload() { this._unloaded = true; this._mapRevision++ },
  onShow() { this._refreshMarkers() },

  onFilterChange(e) {
    const filter = e.currentTarget.dataset.filter
    if (['all', 'disease', 'healthy'].indexOf(filter) < 0 || filter === this.data.activeFilter) return
    this.setData({ activeFilter: filter }, () => this._refreshMarkers())
  },

  onGoHistory() { wx.redirectTo({ url: '/pages/history/history' }) },

  onViewPoints(e) {
    const filter = e.currentTarget.dataset.filter
    if (filter !== 'all' && filter !== 'disease') return
    this.setData({ activeFilter: filter, showPointList: true,
      pointListTitle: filter === 'disease' ? '疑似病害照片' : '已标记的照片位置' }, () => this._refreshMarkers())
  },

  onClosePointList() { this.setData({ showPointList: false }, () => this._fitMarkers()) },
  onStopPointTouch() {},

  onOpenPhotoReport(e) {
    const photo = this.data.mapPhotos.find(function(item) { return String(item.markerId) === String(e.currentTarget.dataset.markerId) })
    if (photo) wx.navigateTo({ url: '/pages/index/index?historyId=' + photo.recordId })
  },

  onFocusPhoto(e) {
    const photo = this.data.mapPhotos.find(function(item) { return String(item.markerId) === String(e.currentTarget.dataset.markerId) })
    if (!photo) return
    this._mapRevision++
    this._viewState = null
    const markers = this.data.markers.map(function(marker) {
      return Object.assign({}, marker, { callout: Object.assign({}, marker.callout, { display: marker.id === photo.markerId ? 'ALWAYS' : 'BYCLICK' }) })
    })
    this.setData({ showPointList: false, longitude: photo.longitude, latitude: photo.latitude, scale: 17, markers: markers })
  },

  onMapTypeChange(e) {
    const type = e.currentTarget.dataset.type
    if ((type !== 'standard' && type !== 'satellite') || type === this.data.mapType) return
    this.setData(Object.assign({}, this._viewState || {}, { mapType: type }))
  },

  onRegionChange(e) {
    const detail = e.detail || {}
    if (e.type !== 'end' && detail.type !== 'end') return
    const center = detail.centerLocation
    if (!center || !Number.isFinite(center.latitude) || !Number.isFinite(center.longitude)) return
    this._viewState = { latitude: center.latitude, longitude: center.longitude }
    if (Number.isFinite(detail.scale)) this._viewState.scale = detail.scale
  },

  async onLocate() {
    if (this.data.locating) return
    const revision = this._mapRevision
    this.setData({ locating: true })
    try {
      const location = await getDeviceLocation(wx)
      if (this._unloaded || revision !== this._mapRevision) return
      if (location.status !== 'located') {
        if (location.reason === 'permission-denied') showPermissionGuide(wx)
        else wx.showToast({ title: location.reason === 'timeout' ? '定位超时，请稍后重试' : '当前位置暂不可用', icon: 'none' })
        return
      }
      const point = wgs84ToGcj02(location)
      this._viewState = null
      this.setData({ longitude: point.lng, latitude: point.lat, showLocation: true })
    } finally {
      if (!this._unloaded) this.setData({ locating: false })
    }
  },

  onOpenMarker(e) {
    const id = this._markerRecords && this._markerRecords[e.detail.markerId]
    if (id != null) wx.navigateTo({ url: '/pages/index/index?historyId=' + id })
  },

  _refreshMarkers() {
    this._mapRevision = (this._mapRevision || 0) + 1
    this._viewState = null
    try {
      const result = buildMarkers(historyStore.load(wx), this.data.activeFilter)
      this._markerRecords = result.recordIds
      const state = {
        markers: result.markers, mapPhotos: result.photos, markedCount: result.markedCount,
        diseaseCount: result.diseaseCount, mapError: ''
      }
      if (result.markers.length) {
        state.latitude = result.markers[0].latitude
        state.longitude = result.markers[0].longitude
      }
      this.setData(state, () => this._fitMarkers())
    } catch (error) {
      console.error('[Map] 刷新标记失败', error)
      this._markerRecords = {}
      this.setData({ markers: [], mapPhotos: [], markedCount: 0, diseaseCount: 0, mapError: '本机地图记录读取失败，请稍后重试' })
    }
  },

  _fitMarkers() {
    if (!this._mapReady || this._unloaded || this.data.showPointList || !this.data.markers.length) return
    wx.createMapContext('diseaseMap', this).includePoints({
      points: this.data.markers.map(function(marker) { return { latitude: marker.latitude, longitude: marker.longitude } }),
      padding: [56, 36, 56, 36],
      fail: function() { console.warn('[Map] 无法自动调整视野，可手动缩放地图') }
    })
  }
})
