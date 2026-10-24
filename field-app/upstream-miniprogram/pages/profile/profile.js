const historyStore = require('../../utils/history-store')

Page({
  data: {
    locationStatus: 'checking',
    locationLabel: '读取中',
    recordCount: 0,
    historyLimit: historyStore.HISTORY_MAX,
    historyError: '',
    recordProgress: 0,
    privacyExpanded: false,
    clearing: false,
    openingSettings: false,
    versionText: '暂不可用'
  },

  onLoad() {
    this._unloaded = false
    this._permissionRevision = 0
    try {
      const info = wx.getAccountInfoSync().miniProgram || {}
      this.setData({ versionText: info.version || (info.envVersion === 'develop' ? '开发版' : (info.envVersion === 'trial' ? '体验版' : '暂不可用')) })
    } catch (error) { /* Version information is optional outside the WeChat runtime. */ }
  },

  onUnload() {
    this._unloaded = true
    this._permissionRevision++
  },

  onShow() {
    this._loadPermission()
    this._loadRecordCount()
  },

  _loadPermission() {
    const revision = ++this._permissionRevision
    this.setData({ locationStatus: 'checking', locationLabel: '读取中' })
    const fail = () => {
      if (!this._unloaded && revision === this._permissionRevision) {
        this.setData({ locationStatus: 'unavailable', locationLabel: '暂不可读取' })
      }
    }
    try {
      wx.getSetting({
        success: (res) => {
          if (this._unloaded || revision !== this._permissionRevision) return
          if (!res.authSetting || typeof res.authSetting !== 'object') { fail(); return }
          const permission = res.authSetting['scope.userLocation']
          this.setData({
            locationStatus: permission === true ? 'allowed' : (permission === false ? 'denied' : 'unrequested'),
            locationLabel: permission === true ? '已开启' : (permission === false ? '已拒绝' : '未授权')
          })
        },
        fail: fail
      })
    } catch (error) { fail() }
  },

  _loadRecordCount() {
    try {
      const count = historyStore.load(wx).length
      this.setData({ recordCount: count, recordProgress: Math.min(100, Math.round(count / historyStore.HISTORY_MAX * 100)), historyError: '' })
    } catch (error) {
      this.setData({ historyError: '本机记录暂不可读取，请返回后重试。' })
    }
  },

  onOpenSettings() {
    if (this.data.openingSettings) return
    this.setData({ openingSettings: true })
    wx.openSetting({
      success: () => { if (!this._unloaded) this._loadPermission() },
      fail: () => { if (!this._unloaded) wx.showToast({ title: '设置未打开，请重试', icon: 'none' }) },
      complete: () => { if (!this._unloaded) this.setData({ openingSettings: false }) }
    })
  },

  onManageRecords() { wx.navigateTo({ url: '/pages/history/history?manage=select' }) },

  onTogglePrivacy() { this.setData({ privacyExpanded: !this.data.privacyExpanded }) },

  onClearHistory() {
    if (this.data.clearing) return
    this.setData({ clearing: true })
    wx.showModal({
      title: '清空本机记录？',
      content: '将删除本机全部检测记录、照片位置及保存的照片，地图标记也会清空，操作无法撤销。相册中另存的报告需自行删除。',
      confirmText: '确认清空',
      confirmColor: '#B04A40',
      success: (res) => {
        if (!res.confirm || this._unloaded) return
        try {
          historyStore.clear(wx)
          this.setData({ recordCount: 0, recordProgress: 0, historyError: '' })
          wx.showToast({ title: '本机记录已清空', icon: 'success' })
        } catch (error) {
          wx.showToast({ title: '清空失败，请重试', icon: 'none' })
        }
      },
      complete: () => { if (!this._unloaded) this.setData({ clearing: false }) }
    })
  }
})
