const historyStore = require('../../utils/history-store')
const { isLocationEligible } = require('../../utils/location')
const { wgs84ToGcj02 } = require('../../utils/coordinates')
const { chooseManualLocation, locationFromManualCoordinates, showPermissionGuide } = require('../../utils/location-service')
const { headerLayout } = require('../../utils/header-layout')

Page({
  data: {
    historyList: [], historyError: '', editingLocation: false,
    headerTopInset: 30, headerNavHeight: 32, headerRightInset: 112,
    selectingRecords: false, selectedRecordIds: [], selectedCount: 0, allRecordsSelected: false, clearing: false,
    locationSheet: '', locationPhotos: [], locationImageLabel: '', locationHasPoint: false,
    manualLongitude: '', manualLatitude: '', manualCoordSystem: 'wgs84',
    locationFormError: '', choosingMap: false, locationKeyboardHeight: 0, locationBodyHeight: 330, locationScrollIntoView: ''
  },

  onLoad(options) {
    this._unloaded = false
    this._manageOnShow = options && options.manage === 'select'
    this.setData(headerLayout(wx))
  },
  onUnload() { this._unloaded = true; this._locationSession = (this._locationSession || 0) + 1; this._locationTarget = null },

  onShow() {
    this._loadHistory()
    if (this._manageOnShow) { this._manageOnShow = false; this.onStartSelection() }
  },

  onOpenProfile() {
    wx.navigateTo({ url: '/pages/profile/profile' })
  },

  _loadHistory() {
    try {
      const list = historyStore.load(wx).sort(function(a, b) { return b.id - a.id })
      const selected = new Set(this.data.selectedRecordIds.map(String))
      const historyList = list.map(function(record) {
        const total = record.locationEligibleCount
        const locationSummary = record.sortedResults.length
          ? (total ? record.locationCount + '/' + total + ' 张有效结果有位置' : '暂无有效识别结果')
          : (record.hasAnyGps ? '旧版批次位置，建议核对' : '尚未记录田块位置')
        return Object.assign({}, record, { locationSummary: locationSummary, selected: selected.has(String(record.id)) })
      })
      const ids = historyList.filter(function(record) { return record.selected }).map(function(record) { return String(record.id) })
      this.setData({ historyList: historyList, historyError: '', selectedRecordIds: ids,
        selectedCount: ids.length, allRecordsSelected: ids.length > 0 && ids.length === historyList.length,
        selectingRecords: this.data.selectingRecords && historyList.length > 0 })
    } catch (error) {
      console.error('[History] 读取历史失败', error)
      this.setData({ historyList: [], historyError: '本机记录读取失败，请稍后重试', selectingRecords: false,
        selectedRecordIds: [], selectedCount: 0, allRecordsSelected: false })
    }
  },

  onOpenRecord(e) {
    if (this.data.selectingRecords) { this.onToggleSelection(e); return }
    wx.navigateTo({ url: '/pages/index/index?historyId=' + e.currentTarget.dataset.id })
  },

  onToggleMapMark(e) {
    if (this.data.selectingRecords) return
    try {
      const record = historyStore.toggleMapMark(e.currentTarget.dataset.id, wx)
      this._loadHistory()
      wx.showToast({ title: record.isMapMarked ? '已标记有位置的照片' : '已取消标记', icon: 'success' })
    } catch (error) {
      wx.showToast({ title: error.message || '操作失败', icon: 'none', duration: 2500 })
    }
  },

  onEditLocation(e) {
    if (this.data.editingLocation || this.data.selectingRecords) return
    const id = e.currentTarget.dataset.id
    try {
      const record = historyStore.load(wx).find(function(item) { return String(item.id) === String(id) })
      if (!record || !record.sortedResults.length) throw new Error('该旧记录缺少逐张照片信息')
      const photos = record.sortedResults.filter(isLocationEligible).map(function(result) {
        return { imageIndex: result.imageIndex, label: '图片 ' + result.imageIndex,
          name: result.predicted_class || '检测结果', hasPoint: result.location.status === 'located' }
      })
      if (!photos.length) throw new Error('没有可补位置的有效结果，请先重拍')
      this._locationRecordId = id
      this._locationSession = (this._locationSession || 0) + 1
      this.setData({ editingLocation: true, locationSheet: 'photo', locationPhotos: photos,
        locationFormError: '', locationKeyboardHeight: 0 })
      if (photos.length === 1) this._selectLocationPhoto(photos[0].imageIndex)
    } catch (error) {
      wx.showToast({ title: error.message || '位置读取失败', icon: 'none', duration: 2500 })
    }
  },

  onSelectLocationPhoto(e) { this._selectLocationPhoto(e.currentTarget.dataset.imageIndex) },

  _selectLocationPhoto(imageIndex) {
    if (!this.data.editingLocation || this.data.choosingMap) return
    try {
      const record = historyStore.load(wx).find((item) => String(item.id) === String(this._locationRecordId))
      const image = record && record.sortedResults.find(function(item) { return String(item.imageIndex) === String(imageIndex) })
      if (!isLocationEligible(image)) throw new Error('该照片未通过识别，请重拍后再补位置')
      this._locationTarget = { id: record.id, imageIndex: image.imageIndex, location: image.location }
      this._coordinateDraftChanged = false
      const hasPoint = image.location.status === 'located'
      this.setData({ locationSheet: 'edit', locationImageLabel: '图片 ' + image.imageIndex + ' · ' + (image.predicted_class || '检测结果'),
        locationHasPoint: hasPoint, manualLongitude: hasPoint ? String(image.location.lng) : '',
        manualLatitude: hasPoint ? String(image.location.lat) : '', manualCoordSystem: 'wgs84', locationFormError: '' })
      this._resizeLocationBody(0)
    } catch (error) {
      this.onCloseLocationSheet()
      wx.showToast({ title: error.message || '照片读取失败', icon: 'none' })
    }
  },

  onLocationInput(e) {
    if (!this._locationTarget || this.data.choosingMap) return
    const field = e.currentTarget.dataset.field
    if (field !== 'manualLongitude' && field !== 'manualLatitude') return
    this._coordinateDraftChanged = true
    this.setData({ [field]: e.detail.value, locationFormError: '' })
  },

  onBackLocationPhotos() {
    if (this.data.choosingMap || this.data.locationPhotos.length < 2) return
    this._locationTarget = null
    this._focusedCoordinateField = null
    this.setData({ locationSheet: 'photo', locationFormError: '', locationKeyboardHeight: 0, locationScrollIntoView: '' })
    if (wx.hideKeyboard) wx.hideKeyboard()
  },

  onCoordinateSystemChange(e) {
    if (!this._locationTarget || this.data.choosingMap) return
    const system = e.currentTarget.dataset.system
    if ((system !== 'wgs84' && system !== 'gcj02') || system === this.data.manualCoordSystem) return
    const state = { manualCoordSystem: system, locationFormError: '' }
    // Existing saved points change representation; typed coordinates keep their
    // literal values so the user can choose the source type before or after entry.
    if (!this._coordinateDraftChanged && this._locationTarget.location.status === 'located') {
      const point = system === 'gcj02' ? wgs84ToGcj02(this._locationTarget.location) : this._locationTarget.location
      state.manualLongitude = String(point.lng)
      state.manualLatitude = String(point.lat)
    }
    this.setData(state)
  },

  onSaveCoordinates() {
    if (!this._locationTarget || this.data.choosingMap) return
    try {
      const location = locationFromManualCoordinates({ lng: this.data.manualLongitude, lat: this.data.manualLatitude }, this.data.manualCoordSystem)
      this._commitLocation(location)
    } catch (error) {
      this.setData({ locationFormError: error.message || '位置保存失败，请重试', locationScrollIntoView: '' }, () => {
        this.setData({ locationScrollIntoView: 'location-coordinate-error' })
      })
    }
  },

  async onChooseMapLocation() {
    if (!this._locationTarget || this.data.choosingMap) return
    const session = this._locationSession
    const current = this._locationTarget.location
    this.setData({ choosingMap: true, locationFormError: '', locationKeyboardHeight: 0 })
    this._resizeLocationBody(0)
    if (wx.hideKeyboard) wx.hideKeyboard()
    try {
      const location = await chooseManualLocation(wx, current)
      if (this._unloaded || session !== this._locationSession || location.reason === 'cancelled') return
      if (location.status !== 'located') {
        this.setData({ locationFormError: '未选定位置，可重试或手动填写经纬度' })
        if (location.reason === 'permission-denied') showPermissionGuide(wx)
        return
      }
      this._commitLocation(location)
    } catch (error) {
      if (!this._unloaded && session === this._locationSession) this.setData({ locationFormError: error.message || '位置保存失败，请重试' })
    } finally {
      if (!this._unloaded && session === this._locationSession) this.setData({ choosingMap: false })
    }
  },

  _commitLocation(location) {
    const target = this._locationTarget
    if (!target || this._unloaded) return
    historyStore.setImageLocation(target.id, target.imageIndex, location, wx)
    this._closeLocationSheet()
    this._loadHistory()
    wx.showToast({ title: '已更新所选照片位置', icon: 'success' })
  },

  onCloseLocationSheet() {
    if (!this.data.choosingMap) this._closeLocationSheet()
  },

  _closeLocationSheet() {
    this._locationSession = (this._locationSession || 0) + 1
    this._locationTarget = null
    this._locationRecordId = null
    this._focusedCoordinateField = null
    this.setData({ editingLocation: false, locationSheet: '', locationPhotos: [],
      manualLongitude: '', manualLatitude: '', locationFormError: '', choosingMap: false, locationKeyboardHeight: 0, locationScrollIntoView: '' })
    if (wx.hideKeyboard) wx.hideKeyboard()
  },

  onLocationKeyboardChange(e) { this._resizeLocationBody(Number(e.detail.height) || 0) },

  onLocationFocus(e) {
    const field = e.currentTarget.dataset.field
    if (field !== 'manualLongitude' && field !== 'manualLatitude') return
    this._focusedCoordinateField = field
    if (this.data.locationKeyboardHeight > 0) this.setData({ locationScrollIntoView: 'location-' + field })
  },

  _resizeLocationBody(keyboardHeight) {
    let windowHeight = 700
    let safeBottom = 0
    try {
      const info = wx.getWindowInfo ? wx.getWindowInfo() : wx.getSystemInfoSync()
      if (info && Number.isFinite(info.windowHeight)) windowHeight = info.windowHeight
      if (info && info.safeArea && Number.isFinite(info.screenHeight) && Number.isFinite(info.safeArea.bottom)) {
        safeBottom = Math.max(0, info.screenHeight - info.safeArea.bottom)
      }
    } catch (error) { /* The form remains scrollable with the fallback height. */ }
    const topClearance = Math.max(88, this.data.headerTopInset + this.data.headerNavHeight + 12)
    const available = windowHeight - topClearance - keyboardHeight - 160 - safeBottom
    this.setData({ locationKeyboardHeight: keyboardHeight, locationBodyHeight: Math.max(64, Math.min(330, available)), locationScrollIntoView: '' }, () => {
      if (keyboardHeight > 0 && this._focusedCoordinateField) this.setData({ locationScrollIntoView: 'location-' + this._focusedCoordinateField })
    })
  },

  onStopLocationTouch() {},

  onManageHistory() {
    if (this.data.clearing) return
    wx.showActionSheet({
      itemList: ['选择记录清理', '清空全部记录'],
      success: (res) => {
        if (this._unloaded) return
        if (res.tapIndex === 0) this.onStartSelection()
        else if (res.tapIndex === 1) this.onClearAll()
      }
    })
  },

  onStartSelection() {
    if (this.data.clearing || !this.data.historyList.length) return
    this._setSelectedRecords([])
    this.setData({ selectingRecords: true })
  },

  _setSelectedRecords(ids) {
    const selected = new Set(ids.map(String))
    const list = this.data.historyList.map(function(record) {
      return Object.assign({}, record, { selected: selected.has(String(record.id)) })
    })
    const visibleIds = list.filter(function(record) { return record.selected }).map(function(record) { return String(record.id) })
    this.setData({ historyList: list, selectedRecordIds: visibleIds, selectedCount: visibleIds.length,
      allRecordsSelected: visibleIds.length > 0 && visibleIds.length === list.length })
  },

  onToggleSelection(e) {
    if (!this.data.selectingRecords || this.data.clearing) return
    const id = String(e.currentTarget.dataset.id)
    if (!this.data.historyList.some(function(record) { return String(record.id) === id })) return
    const ids = this.data.selectedRecordIds.slice()
    const index = ids.indexOf(id)
    if (index < 0) ids.push(id)
    else ids.splice(index, 1)
    this._setSelectedRecords(ids)
  },

  onSelectAll() {
    if (!this.data.selectingRecords || this.data.clearing) return
    this._setSelectedRecords(this.data.allRecordsSelected ? [] : this.data.historyList.map(function(record) { return String(record.id) }))
  },

  onCancelSelection() {
    if (this.data.clearing) return
    this._setSelectedRecords([])
    this.setData({ selectingRecords: false })
  },

  onDeleteSelected() {
    if (this.data.clearing || !this.data.selectedRecordIds.length) return
    const ids = this.data.selectedRecordIds.slice()
    this.setData({ clearing: true })
    wx.showModal({
      title: '删除所选 ' + ids.length + ' 条记录？',
      content: '将一并删除这些记录的本机照片、位置和地图标记，无法撤销。其他记录会保留。',
      confirmText: '确认删除', confirmColor: '#B04A40',
      success: (res) => {
        if (!res.confirm || this._unloaded) return
        try {
          const count = historyStore.removeSelected(ids, wx)
          this.setData({ selectingRecords: false, selectedRecordIds: [] })
          this._loadHistory()
          wx.showToast({ title: count ? '已删除 ' + count + ' 条记录' : '所选记录已不存在', icon: count ? 'success' : 'none' })
        } catch (error) {
          wx.showToast({ title: '删除失败，请重试', icon: 'none' })
        }
      },
      complete: () => { if (!this._unloaded) this.setData({ clearing: false }) }
    })
  },

  onClearAll() {
    if (this.data.clearing) return
    this.setData({ clearing: true })
    wx.showModal({
      title: '清空全部本机记录？',
      content: '将删除全部检测记录、本机照片、照片位置和地图标记，无法撤销。相册中另存的报告需自行删除。',
      confirmText: '确认清空', confirmColor: '#B04A40',
      success: (res) => {
        if (!res.confirm || this._unloaded) return
        try {
          historyStore.clear(wx)
          this.setData({ historyList: [], historyError: '', selectingRecords: false,
            selectedRecordIds: [], selectedCount: 0, allRecordsSelected: false })
          wx.showToast({ title: '历史记录已清空', icon: 'success' })
        } catch (error) {
          console.error('[History] 清空失败', error)
          wx.showToast({ title: '清空失败', icon: 'none' })
        }
      },
      complete: () => { if (!this._unloaded) this.setData({ clearing: false }) }
    })
  }
})
