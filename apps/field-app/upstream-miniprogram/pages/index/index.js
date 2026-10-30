// pages/index/index.js

// ==================== 配置区 ====================
const API_BASE_URL = 'https://rice-srt.cn'
const PREDICT_URL = API_BASE_URL + '/batch_predict'
const FILE_FIELD_NAME = 'files'
const MOCK_MODE = false
// ================================================

const historyStore = require('../../utils/history-store')
const profiles = require('./disease-profiles')
const JUDGMENT_NUMBERS = ['①', '②', '③', '④']
const { RECORD_LOCATION_VERSION, unavailable, normalizeResult, recordPoints } = require('../../utils/location')
const { resolveImageLocations, showPermissionGuide } = require('../../utils/location-service')
const { headerLayout } = require('../../utils/header-layout')
const navigationState = require('../../utils/navigation-state')

function attachImageLocation(result, image) {
  return withResultDetails(normalizeResult(Object.assign({}, result, {
    imagePath: image.path, imageIndex: image.index, imageId: image.imageId,
    origin: image.origin, selectedAt: image.selectedAt, imageFormat: image.imageFormat,
    location: image.location || unavailable('unknown-origin')
  })))
}

// ==================== 模拟结果模板 ====================
const MOCK_RESULTS_TEMPLATES = [
  {
    predicted_class: '稻瘟病',
    confidence: 0.9623,
    is_valid: true,
    message: '检测成功',
    top3_predictions: [
      ['稻瘟病', 0.9623],
      ['褐斑病', 0.0211],
      ['健康水稻', 0.0085]
    ]
  },
  {
    predicted_class: '其他',
    confidence: 0.7142,
    is_valid: false,
    message: '无效图片或置信度过低',
    top3_predictions: [
      ['其他', 0.7142],
      ['健康水稻', 0.1021],
      ['褐斑病', 0.0683]
    ]
  },
  {
    predicted_class: '褐斑病',
    confidence: 0.8831,
    is_valid: true,
    message: '检测成功',
    top3_predictions: [
      ['褐斑病', 0.8831],
      ['稻瘟病', 0.0741],
      ['健康水稻', 0.0312]
    ]
  },
  {
    predicted_class: '健康水稻',
    confidence: 0.9412,
    is_valid: true,
    message: '检测成功',
    top3_predictions: [
      ['健康水稻', 0.9412],
      ['稻瘟病', 0.0321],
      ['褐斑病', 0.0201]
    ]
  },
  {
    predicted_class: '其他',
    confidence: 0.5513,
    is_valid: false,
    message: '无效图片或置信度过低',
    top3_predictions: [
      ['其他', 0.5513],
      ['稻瘟病', 0.2211],
      ['健康水稻', 0.1501]
    ]
  },
  {
    predicted_class: '纹枯病',
    confidence: 0.8024,
    is_valid: true,
    message: '检测成功',
    top3_predictions: [
      ['纹枯病', 0.8024],
      ['褐斑病', 0.1102],
      ['稻瘟病', 0.0501]
    ]
  }
]

// ==================== 工具函数 ====================

// 格式化置信度为简洁百分比字符串（1 位小数）
function formatConfidence(confidence) {
  if (confidence === null || confidence === undefined || isNaN(confidence)) {
    return '0%'
  }
  return (confidence * 100).toFixed(1) + '%'
}

// 计算展示状态枚举
// 'healthy'  → 健康水稻且有效
// 'disease'  → 检测到病害且有效
// 'invalid'  → 无效图片（"其他"类或置信度不足）
// 'fail'     → 检测失败（网络/解析错误）
function calcDisplayStatus(predicted_class, is_valid) {
  if (predicted_class === '检测失败') return 'fail'
  if (predicted_class === '其他' || !is_valid) return 'invalid'
  if (predicted_class === '健康水稻') return 'healthy'
  return 'disease'
}

// 将 top3_predictions 转换为 top3Items
// 低于 5% 的项标记 isFolded:true，默认隐藏
var MIN_SHOW_CONFIDENCE = 0.05

function formatTop3(top3_predictions) {
  if (!Array.isArray(top3_predictions)) return []
  return top3_predictions.map(function(item) {
    var name = Array.isArray(item) ? item[0] : item.name
    var rawConfidence = Array.isArray(item) ? item[1] : item.confidence
    var confidence = Number(rawConfidence) || 0
    var percent = Math.max(0, Math.min(100, confidence * 100))
    return {
      name: name || '未知类别',
      confidence: confidence,
      confidenceText: percent.toFixed(1) + '%',
      barWidth: percent.toFixed(1) + '%',
      isFolded: confidence < MIN_SHOW_CONFIDENCE
    }
  })
}

// Rebuild display-only content, including when reading reports from earlier versions.
function withResultDetails(result) {
  const value = Object.assign({}, result)
  delete value.adviceText
  delete value.profile
  delete value.profileOpen
  if (value.displayStatus === 'disease' && Object.prototype.hasOwnProperty.call(profiles, value.predicted_class)) {
    value.profile = profiles[value.predicted_class]
    value.profileOpen = false
  }
  return value
}

function withoutResultDetails(result) {
  const value = Object.assign({}, result)
  delete value.adviceText
  delete value.profile
  delete value.profileOpen
  return value
}

// 构建失败结果对象
function buildFailResult(imageIndex, message) {
  return {
    displayLabel: '图片 ' + imageIndex,
    predicted_class: '检测失败',
    confidence: 0,
    confidenceText: '0%',
    displayStatus: 'fail',
    is_valid: false,
    message: message || '检测失败',
    top3Items: [],
    showTop3: false
  }
}

// 解析后端返回的 JSON，兼容多种格式
function parseBackendResult(rawData, imageIndex) {
  try {
    const parsed = JSON.parse(rawData)
    let resultObj = null

    if (parsed.results && Array.isArray(parsed.results)) {
      resultObj = parsed.results[0] || null
    } else if (parsed.result && typeof parsed.result === 'object') {
      resultObj = parsed.result
    } else if (parsed.predicted_class !== undefined) {
      resultObj = parsed
    }

    if (!resultObj) {
      return buildFailResult(imageIndex, '后端返回格式无法识别')
    }

    const predicted_class = resultObj.predicted_class || '未知'
    const confidence = resultObj.confidence || 0
    const is_valid = resultObj.is_valid === true
    const displayStatus = calcDisplayStatus(predicted_class, is_valid)
    const top3Items = formatTop3(resultObj.top3_predictions || [])

    // 仅病害展示预测分布，健康/无效/失败均隐藏
    const showTop3 = (displayStatus === 'disease')

    return {
      displayLabel: '图片 ' + imageIndex,
      predicted_class: predicted_class,
      confidence: confidence,
      confidenceText: formatConfidence(confidence),
      displayStatus: displayStatus,
      is_valid: is_valid,
      message: resultObj.message || '',
      top3Items: top3Items,
      showTop3: showTop3
    }
  } catch (e) {
    return buildFailResult(imageIndex, 'JSON 解析失败: ' + e.message)
  }
}

// 计算综合报告摘要。
function computeSummary(results) {
  var diseaseList = []
  var healthyCount = 0
  var diseaseCount = 0
  var invalidCount = 0
  var failCount = 0

  results.forEach(function(r) {
    if (r.displayStatus === 'healthy') {
      healthyCount++
    } else if (r.displayStatus === 'disease') {
      diseaseCount++
      diseaseList.push(r.predicted_class)
    } else if (r.displayStatus === 'invalid') {
      invalidCount++
    } else if (r.displayStatus === 'fail') {
      failCount++
    }
  })

  // 去重病害名称
  var uniqueDiseases = []
  diseaseList.forEach(function(v) {
    if (uniqueDiseases.indexOf(v) === -1) uniqueDiseases.push(v)
  })

  return {
    hasResults: results.length > 0,
    isAllHealthy: diseaseCount === 0 && invalidCount === 0 && failCount === 0 && healthyCount > 0,
    hasDisease: diseaseCount > 0,
    diseaseNamesText: uniqueDiseases.join('、'),
    healthyCount: healthyCount,
    diseaseCount: diseaseCount,
    invalidCount: invalidCount,
    failCount: failCount,
    total: results.length
  }
}

// 对结果排序：disease → healthy → invalid → fail
var STATUS_ORDER = { 'disease': 0, 'healthy': 1, 'invalid': 2, 'fail': 3 }
function sortResults(results) {
  return results.slice().sort(function(a, b) {
    var orderA = STATUS_ORDER[a.displayStatus] !== undefined ? STATUS_ORDER[a.displayStatus] : 4
    var orderB = STATUS_ORDER[b.displayStatus] !== undefined ? STATUS_ORDER[b.displayStatus] : 4
    return orderA - orderB
  })
}

// ==================== 历史记录工具函数 ====================

// 格式化时间戳为可读字符串
function formatTime(ts) {
  var d = new Date(ts)
  var pad = function(n) { return n < 10 ? '0' + n : '' + n }
  return d.getFullYear() + '-' + pad(d.getMonth() + 1) + '-' + pad(d.getDate())
    + ' ' + pad(d.getHours()) + ':' + pad(d.getMinutes())
}

// 将临时路径另存为永久路径（Promise）
function saveTempFile(tempPath, destPath) {
  return new Promise(function(resolve, reject) {
    let settled = false
    let abandoned = false
    const timer = setTimeout(function() { finish(new Error('本地图片保存超时')) }, 8000)
    function finish(error) {
      if (settled) {
        // The caller kept the original path after a timeout. A late copy is no
        // longer part of any record and must not remain after data deletion.
        if (abandoned && !error) {
          try { wx.getFileSystemManager().unlinkSync(destPath) } catch (cleanupError) { /* A subsequent clear can retry. */ }
        }
        return
      }
      settled = true
      abandoned = !!error
      clearTimeout(timer)
      error ? reject(error) : resolve(destPath)
    }
    try {
      // Copy keeps the original usable if the operation fails or times out.
      wx.getFileSystemManager().copyFile({
        srcPath: tempPath, destPath: destPath,
        success: function() { finish() }, fail: finish
      })
    } catch (error) { finish(error) }
  })
}

// =========================================================

// ==================== Page ====================
Page({
  data: {
    images: [],
    results: [],         // 原始结果数组（与 images 一一对应）
    sortedResults: [],   // 排序后用于渲染的数组
    summary: {           // 综合报告摘要
      hasResults: false,
      isAllHealthy: false,
      hasDisease: false,
      diseaseNamesText: '',
      healthyCount: 0,
      diseaseCount: 0,
      invalidCount: 0,
      failCount: 0,
      total: 0,
      time: ''
    },
    loading: false,
    selecting: false,
    savingHistory: false,
    statusText: '',
    errorText: '',
    isHistoryView: false,   // 是否为历史回看模式
    historyTime: '',         // 历史记录检测时间
    posterStyle: '',         // Canvas 动态 style（宽高，px 单位）
    posterReady: false,      // 永久路径已保存完成，可以生成海报
    judgmentNumbers: JUDGMENT_NUMBERS,
    reportScrollTop: 0,
    reportScrollAnimated: true,
    headerTopInset: 30, headerNavHeight: 32, headerRightInset: 112,
    nearbyRiskText: '暂无已标记的病害位置'
  },

  // 页面加载：支持历史记录回看
  onLoad(options) {
    this._unloaded = false
    this._selectionToken = 0
    this._detectionToken = 0
    this._leavingHistoryReport = false
    this._currentReportScrollTop = 0
    this.setData(headerLayout(wx))
    if (options && options.historyId) {
      this._restoreHistory(parseInt(options.historyId), options.resume === '1')
    }
  },

  onUnload() {
    this._rememberHistoryReport()
    this._unloaded = true
    this._selectionToken++
    this._detectionToken++
    clearTimeout(this._restoreTimer)
    this._clearDiseasePreviews()
  },

  onHide() { this._rememberHistoryReport() },

  onReportScroll(e) { this._currentReportScrollTop = Number(e.detail.scrollTop) || 0 },

  _rememberHistoryReport() {
    if (!this.data.isHistoryView || !this.data.summary.hasResults || this._leavingHistoryReport || this._reportHistoryId == null) return
    navigationState.rememberHistoryReport({ id: this._reportHistoryId, scrollTop: this._currentReportScrollTop,
      expandedImages: this.data.sortedResults.filter(function(result) { return result.profileOpen }).map(function(result) { return result.imageIndex }) })
  },

  onShow() {
    if (this._reportHistoryId != null) {
      try {
        if (!historyStore.load(wx).some((record) => String(record.id) === String(this._reportHistoryId))) {
          this.onRetest()
        }
      } catch (error) { /* A temporary read failure must not erase the visible report. */ }
    }
    this._refreshLocalRisk()
  },

  // 根据本机已标记的历史记录更新首页风险提示，不伪造在线区域预警。
  _refreshLocalRisk() {
    try {
      var riskCount = 0
      historyStore.load(wx).filter(function(record) { return record.isMapMarked }).forEach(function(record) {
        riskCount += recordPoints(record).filter(function(point) { return point.status === 'disease' }).length
      })
      this.setData({
        nearbyRiskText: riskCount > 0
          ? '已有 ' + riskCount + ' 个病害位置标记到地图'
          : '暂无已标记的病害位置'
      })
    } catch (e) {
      this.setData({ nearbyRiskText: '本机地图记录暂不可读取' })
    }
  },

  // 跳转到历史记录页
  onNavigateToHistory() {
    wx.navigateTo({ url: '/pages/history/history' })
  },

  // 跳转到周边病害地图页
  goToMap() {
    wx.navigateTo({ url: '/pages/map/map' })
  },

  // 从历史回看返回历史列表
  onReturnToHistory() {
    this._leavingHistoryReport = true
    navigationState.forgetHistoryReport()
    wx.redirectTo({ url: '/pages/history/history', fail: () => {
      this._leavingHistoryReport = false
      this._rememberHistoryReport()
      wx.showToast({ title: '返回失败，请重试', icon: 'none' })
    } })
  },

  // 从 Storage 复原指定历史记录
  _restoreHistory(historyId, resume) {
    try {
      var list = historyStore.load(wx)
      var record = list.find(function(r) { return String(r.id) === String(historyId) })
      if (!record) {
        console.error('[Index] 未找到对应历史记录', historyId)
        return
      }
      this._reportHistoryId = record.id
      this._leavingHistoryReport = false
      const progress = resume ? navigationState.getHistoryReport(record.id) : null
      if (!progress) navigationState.rememberHistoryReport({ id: record.id, scrollTop: 0, expandedImages: [] })
      this._currentReportScrollTop = progress ? progress.scrollTop : 0

      // 第一次 setData：强制清空 images 与 hasResults，标记历史视图
      this.setData({
        isHistoryView: true,
        images: [],
        results: [],
        sortedResults: [],
        summary: { hasResults: false },
        historyTime: record.time || '',
        statusText: '',
        errorText: '',
        posterReady: true,
        reportScrollTop: 0,
        reportScrollAnimated: !progress
      })

      // 200ms 延迟后第二次 setData：填入真实历史数据，规避 JSBridge 超时死锁
      var that = this
      clearTimeout(this._restoreTimer)
      this._restoreTimer = setTimeout(function() {
        if (that._unloaded) return
        // Re-read after the deferred render so a deletion cannot restore a stale report.
        let current = record
        try { current = historyStore.load(wx).find(function(item) { return String(item.id) === String(historyId) }) }
        catch (error) { console.warn('[Index] 复核记录暂不可读，保留已读取的报告') }
        if (!current) { navigationState.forgetHistoryReport(historyId); that.onRetest(); return }
        const restored = (current.sortedResults || []).map(withResultDetails).map(function(result) {
          if (progress && result.profile && progress.expandedImages.indexOf(String(result.imageIndex)) >= 0) result.profileOpen = true
          return result
        })
        const summary = computeSummary(restored)
        // Very old batch-only records keep their counts, without legacy treatment text.
        if (!restored.length && current.summary) {
          Object.assign(summary, current.summary)
          delete summary.globalAdvices
        }
        that._currentReportScrollTop = progress ? progress.scrollTop : 0
        that.setData({
          images: restored,
          results: restored,
          sortedResults: restored,
          summary: Object.assign(summary, {
            hasResults: true,
            time: current.time || ''
          }),
          historyTime: current.time || '',
          reportScrollTop: progress ? progress.scrollTop : 0
        }, () => that._rememberHistoryReport())
      }, 200)
    } catch (e) {
      console.error('[Index] 历史复原失败', e)
    }
  },

  // 保存历史记录到本地文件系统 + Storage
  // Capture each result's location before any asynchronous file operations.
  _saveToHistory(results, summary) {
    const ts = Date.now()
    const token = this._detectionToken
    const historyRevision = this._historyRevisionAtDetection == null ? historyStore.revision() : this._historyRevisionAtDetection
    const baseDir = wx.env.USER_DATA_PATH

    // 仅处理有有效路径的 result
    const validResults = results.map(function(result, index) { return { result: result, originalIndex: index } })
      .filter(function(item) { return !!item.result.imagePath })
    const savePromises = validResults.map(function(item, idx) {
      const r = item.result
      const extensions = { jpeg: '.jpg', png: '.png', webp: '.webp', heif: '.heic' }
      const pathExtension = /\.(jpe?g|png|webp|hei[cf])(?:\?|$)/i.exec(r.imagePath)
      const ext = extensions[r.imageFormat] || (pathExtension ? '.' + pathExtension[1].toLowerCase() : '.jpg')
      const destPath = baseDir + '/rice_' + ts + '_' + idx + ext
      return saveTempFile(r.imagePath, destPath).then(function(savedPath) {
        return { originalIndex: item.originalIndex, savedPath: savedPath, permanent: true }
      }).catch(function() {
        return { originalIndex: item.originalIndex, savedPath: r.imagePath, permanent: false }
      })
    })

    return Promise.all(savePromises).then((savedList) => {
      // 构建带永久路径的 results 副本
      const savedResults = results.map(function(r, i) {
        const matched = savedList.find(function(s) { return s.originalIndex === i })
        const newPath = matched ? matched.savedPath : (r.imagePath || '')
        return Object.assign({}, r, { imagePath: newPath })
      })

      const permanentPaths = savedList.filter(function(s) { return s.permanent }).map(function(s) { return s.savedPath }).filter(Boolean)
      const thumbnailPath = savedResults.length > 0 ? savedResults[0].imagePath : ''

      const record = {
        id: ts,
        time: formatTime(ts),
        imageCount: validResults.length,
        thumbnailPath: thumbnailPath,
        locationVersion: RECORD_LOCATION_VERSION,
        isMapMarked: false,
        summary: {
          hasResults: true,
          time: formatTime(ts),
          isAllHealthy: summary.isAllHealthy,
          hasDisease: summary.hasDisease,
          diseaseNamesText: summary.diseaseNamesText,
          total: summary.total,
          diseaseCount: summary.diseaseCount,
          healthyCount: summary.healthyCount,
          invalidCount: summary.invalidCount,
          failCount: summary.failCount
        },
        sortedResults: savedResults.map(withoutResultDetails),
        permanentPaths: permanentPaths
      }

      if (this._appendHistory(record, historyRevision) === false) {
        if (!this._unloaded && token === this._detectionToken) {
          this.setData({ savingHistory: false })
          this.onRetest()
        }
        return
      }
      this._reportHistoryId = record.id
      // 图片永久路径已就绪，更新 sortedResults 并标记 posterReady
      if (!this._unloaded && token === this._detectionToken) {
        const displayResults = savedResults.map((result) => {
          const visible = this.data.sortedResults.find(function(item) { return item.imageIndex === result.imageIndex })
          return visible && visible.profile ? Object.assign({}, result, { profileOpen: !!visible.profileOpen }) : result
        })
        this.setData({ sortedResults: displayResults, posterReady: true, savingHistory: false })
        if (savedList.some(function(item) { return !item.permanent })) {
          wx.showToast({ title: '部分照片未永久保存，清理缓存后可能无法回看', icon: 'none', duration: 3000 })
        }
      }
    }).catch((e) => {
      console.error('[Index] 保存历史文件失败', e)
      if (!this._unloaded && token === this._detectionToken) {
        this.setData({ savingHistory: false, posterReady: true })
        wx.showToast({ title: '本地记录保存失败，请保留本次报告', icon: 'none', duration: 3000 })
      }
    })
  },

  // 将新记录写入 Storage，超出限制时清理最旧的
  _appendHistory(record, revision) {
    return historyStore.append(record, wx, revision)
  },

  // 拍照入口
  onTakePhoto() {
    this._chooseImages(['camera'])
  },

  // 相册入口
  onChooseFromAlbum() {
    this._chooseImages(['album'])
  },

  // 兼容旧入口：允许拍照或从相册选择
  onChooseImage() {
    this._chooseImages(['album', 'camera'])
  },

  // 选择图片（增量追加，不覆盖已选）
  _chooseImages(sourceType) {
    if (this.data.selecting || this.data.loading || this.data.savingHistory) return
    if (sourceType.length !== 1) {
      wx.showActionSheet({ itemList: ['拍照', '从相册选择'], success: (res) => {
        this._chooseImages([res.tapIndex === 0 ? 'camera' : 'album'])
      } })
      return
    }
    const current = this.data.images.slice()
    const remaining = 6 - current.length
    if (remaining <= 0) {
      wx.showToast({ title: '最多选 6 张图片', icon: 'none', duration: 1500 })
      return
    }
    const token = (this._selectionToken || 0) + 1
    this._selectionToken = token
    this.setData({ selecting: true })
    wx.chooseImage({
      count: sourceType[0] === 'camera' ? 1 : remaining,
      sizeType: ['original'],
      sourceType: sourceType,
      success: (res) => {
        if (this._unloaded || token !== this._selectionToken) return
        const selectedAt = Date.now()
        var newImages = res.tempFilePaths.slice(0, remaining).map((path, idx) => {
          this._imageSequence = (this._imageSequence || 0) + 1
          return {
            path: path,
            index: current.length + idx + 1,
            imageId: selectedAt + '_' + this._imageSequence,
            origin: sourceType[0], selectedAt: selectedAt,
            location: unavailable('pending'), locationBadge: '读取位置'
          }
        })
        var merged = current.concat(newImages)
        this.setData({
          images: merged,
          results: [],
          sortedResults: [],
          summary: { hasResults: false },
          statusText: '',
          errorText: ''
        })
        resolveImageLocations(newImages, wx).then((resolved) => {
          if (this._unloaded || token !== this._selectionToken) return
          this.setData({ images: current.concat(resolved.map(function(image) { return normalizeResult(image) })), selecting: false })
          if (!this._permissionGuideShown && resolved.some(function(image) { return image.location.reason === 'permission-denied' })) {
            this._permissionGuideShown = true
            showPermissionGuide(wx)
          }
        }).catch(() => {
          if (this._unloaded || token !== this._selectionToken) return
          this.setData({ images: current.concat(newImages.map(function(image) {
            return normalizeResult(Object.assign({}, image, { location: unavailable('read-failed') }))
          })), selecting: false })
          wx.showToast({ title: '位置读取失败，照片仍可识别', icon: 'none' })
        })
      },
      fail: (err) => {
        if (this._unloaded || token !== this._selectionToken) return
        this.setData({ selecting: false })
        if (err.errMsg && err.errMsg.indexOf('cancel') === -1) {
          wx.showToast({ title: '选择图片失败', icon: 'none', duration: 2000 })
        }
      }
    })
  },

  // 删除单张图片，并重新编号
  onDeleteImage(e) {
    if (this.data.selecting || this.data.loading || this.data.savingHistory) return
    const idx = e.currentTarget.dataset.index
    const images = this.data.images.slice()
    images.splice(idx, 1)
    // 重新连续编号
    images.forEach(function(img, i) { img.index = i + 1 })
    this.setData({ images: images })
    if (images.length === 0) {
      wx.showToast({ title: '已清空图片', icon: 'none', duration: 1200 })
    }
  },

  // 再测一次：清空所有状态，回到初始页
  onRetest() {
    if (this.data.loading || this.data.selecting) return
    if (this.data.savingHistory) {
      wx.showToast({ title: '正在保存本地记录，请稍候', icon: 'none' })
      return
    }
    if (this.data.isHistoryView) navigationState.forgetHistoryReport(this._reportHistoryId)
    this._currentReportScrollTop = 0
    this._selectionToken++
    this._detectionToken++
    this._reportHistoryId = null
    clearTimeout(this._restoreTimer)
    this.setData({
      isHistoryView: false,
      images: [],
      results: [],
      sortedResults: [],
      summary: { hasResults: false },
      reportScrollTop: 0,
      reportScrollAnimated: true,
      posterReady: false,
      statusText: '',
      errorText: ''
    })
  },

  onToggleProfile(e) {
    const imageIndex = e.currentTarget.dataset.index
    const index = this.data.sortedResults.findIndex(function(result) { return String(result.imageIndex) === String(imageIndex) })
    const result = this.data.sortedResults[index]
    if (!result || result.displayStatus !== 'disease' || !result.profile) return
    this.setData({ ['sortedResults[' + index + '].profileOpen']: !result.profileOpen })
  },

  onJumpToResults(e) {
    const status = e.currentTarget.dataset.status
    if (['disease', 'healthy', 'retake'].indexOf(status) < 0) return
    const index = this.data.sortedResults.findIndex(function(result) {
      return status === 'retake' ? result.displayStatus === 'invalid' || result.displayStatus === 'fail' : result.displayStatus === status
    })
    if (index < 0) {
      const labels = { disease: '疑似病害', healthy: '健康', retake: '需重拍' }
      wx.showToast({ title: '暂无' + labels[status] + '结果', icon: 'none' })
      return
    }
    const query = wx.createSelectorQuery().in(this)
    query.select('.page-scroll').scrollOffset()
    query.select('.page-scroll').boundingClientRect()
    query.select('#report-result-' + index).boundingClientRect()
    query.exec((values) => {
      if (this._unloaded || !values[0] || !values[1] || !values[2]) return
      let safeTop = 88
      try { safeTop = wx.getMenuButtonBoundingClientRect().bottom + 12 } catch (error) { /* Use the normal navigation inset. */ }
      const current = Number(values[0].scrollTop) || 0
      const target = Math.max(0, current + values[2].top - Math.max(safeTop, values[1].top + 12))
      // 同一统计项再次点击时也按当前滚动位置重新触发跳转。
      this.setData({ reportScrollTop: current, reportScrollAnimated: true }, () => {
        if (!this._unloaded) this.setData({ reportScrollTop: target })
      })
    })
  },

  async onPreviewDiseasePhoto(e) {
    const dataset = e.currentTarget.dataset
    const result = this.data.sortedResults.find(function(item) { return String(item.imageIndex) === String(dataset.resultIndex) })
    const row = result && result.displayStatus === 'disease' && result.profile
    const index = Number(dataset.photoIndex)
    if (!row || !Number.isInteger(index) || !row.photos[index] || this._previewingDiseasePhoto) return
    this._previewingDiseasePhoto = true
    const fs = wx.getFileSystemManager()
    try {
      // 原生预览使用真实本地 JPEG；包内读取路径不带开头的斜杠。
      const urls = await Promise.all(row.photos.map((photo, photoIndex) => new Promise((resolve) => {
        fs.readFile({
          filePath: photo.src.replace(/^\/+/, ''),
          success: (res) => {
            if (this._unloaded) { resolve(''); return }
            const localPath = wx.env.USER_DATA_PATH + '/rice_guide_' + row.id + '_' + photoIndex + '.jpg'
            fs.writeFile({
              filePath: localPath, data: res.data,
              success: () => {
                if (this._unloaded) {
                  try { fs.unlinkSync(localPath) } catch (error) { /* Already removed. */ }
                  resolve('')
                  return
                }
                this._diseasePreviewFiles = this._diseasePreviewFiles || []
                if (this._diseasePreviewFiles.indexOf(localPath) < 0) this._diseasePreviewFiles.push(localPath)
                resolve(localPath)
              },
              fail: () => resolve('')
            })
          },
          fail: () => resolve('')
        })
      })))
      if (this._unloaded) return
      if (!urls[index]) {
        wx.showToast({ title: '这张照片未加载成功，请重试', icon: 'none' })
        return
      }
      wx.previewImage({
        current: urls[index],
        urls: urls.filter(Boolean),
        fail: () => wx.showToast({ title: '照片打开失败，请重试', icon: 'none' })
      })
    } catch (error) {
      if (!this._unloaded) wx.showToast({ title: '照片打开失败，请重试', icon: 'none' })
    } finally {
      this._previewingDiseasePhoto = false
    }
  },

  _clearDiseasePreviews() {
    const paths = this._diseasePreviewFiles || []
    if (!paths.length) return
    const fs = wx.getFileSystemManager()
    paths.forEach(function(filePath) {
      try { fs.unlinkSync(filePath) } catch (error) { /* Preview cache may already be gone. */ }
    })
    this._diseasePreviewFiles = []
  },

  // 大图预览
  onPreviewImage(e) {
    const url = e.currentTarget.dataset.url
    if (!url) return
    // 收集当前所有结果图路径用于左右滑动
    const urls = this.data.sortedResults
      .filter(function(r) { return !!r.imagePath })
      .map(function(r) { return r.imagePath })
    wx.previewImage({
      current: url,
      urls: urls.length > 0 ? urls : [url]
    })
  },

  // 生成 Canvas 海报并保存到相册
  onGeneratePoster() {
    if (!this.data.posterReady) {
      wx.showToast({ title: '图片保存中，请稍后重试', icon: 'none', duration: 2000 })
      return
    }
    this._requestAlbumPermission().then(() => {
      this._drawPoster(this.data.summary, this.data.sortedResults)
    }).catch(() => {
      // 权限被拒绝，已在 _requestAlbumPermission 内提示
    })
  },

  // 请求相册写入权限（返回 Promise）
  _requestAlbumPermission() {
    return new Promise((resolve, reject) => {
      wx.getSetting({
        success: (res) => {
          if (res.authSetting['scope.writePhotosAlbum']) {
            resolve()
          } else {
            wx.authorize({
              scope: 'scope.writePhotosAlbum',
              success: () => resolve(),
              fail: () => {
                // 已拒绝过，引导去设置页
                wx.showModal({
                  title: '需要相册权限',
                  content: '请在设置中开启"保存到相册"权限，才能保存检测报告',
                  confirmText: '去设置',
                  success: (modalRes) => {
                    if (modalRes.confirm) wx.openSetting()
                    reject()
                  },
                  fail: () => reject()
                })
              }
            })
          }
        },
        fail: () => reject()
      })
    })
  },

  // Canvas 2D 绘制海报
  _drawPoster(summary, sortedResults) {
    wx.showLoading({ title: '生成报告中...', mask: true })

    const sysInfo = wx.getSystemInfoSync()
    const rpxToPx = sysInfo.windowWidth / 750   // rpx 转 css px
    const dpr = sysInfo.pixelRatio

    // 画布逻辑尺寸（rpx 单位计算，最终转 px）
    const CANVAS_W_RPX = 680
    const PADDING = 32
    const HEADER_H = 160
    const BANNER_H = 110
    const CARD_H = 200
    const DETAIL_LINE_H = 32
    const detailBlocks = this._posterJudgmentBlocks(sortedResults, DETAIL_LINE_H)
    const DETAIL_H = detailBlocks.reduce(function(height, block) { return height + block.height + 16 }, 0)
    const FOOTER_H = 64

    const totalH = HEADER_H + BANNER_H + sortedResults.length * CARD_H + DETAIL_H + FOOTER_H

    // 物理像素
    const canvasW = Math.round(CANVAS_W_RPX * rpxToPx * dpr)
    const canvasH = Math.round(totalH * rpxToPx * dpr)

    // 更新 Canvas style（px 单位，让 DOM 撑开正确大小）
    const styleW = Math.round(CANVAS_W_RPX * rpxToPx)
    const styleH = Math.round(totalH * rpxToPx)
    this.setData({ posterStyle: 'width:' + styleW + 'px;height:' + styleH + 'px;' })

    const query = wx.createSelectorQuery().in(this)
    query.select('#posterCanvas').fields({ node: true, size: true }).exec((res) => {
      const canvas = res[0].node
      canvas.width = canvasW
      canvas.height = canvasH
      const ctx = canvas.getContext('2d')
      const scale = rpxToPx * dpr
      ctx.scale(scale, scale)

      // ── 背景 ──
      ctx.fillStyle = '#F2F5F2'
      ctx.fillRect(0, 0, CANVAS_W_RPX, totalH)

      // ── 顶部绿色 Header ──
      ctx.fillStyle = '#1B5E20'
      ctx.fillRect(0, 0, CANVAS_W_RPX, HEADER_H)
      ctx.fillStyle = '#FFFFFF'
      ctx.font = 'bold 36px PingFang SC'
      ctx.fillText('稻视界 · 水稻健康诊断报告', PADDING, 56)
      ctx.fillStyle = 'rgba(255,255,255,0.75)'
      ctx.font = '22px PingFang SC'
      ctx.fillText(summary.time || formatTime(Date.now()), PADDING, 96)
      ctx.fillText('共 ' + summary.total + ' 张图片', PADDING, 130)

      // ── Summary Banner ──
      var bannerY = HEADER_H + 16
      if (summary.isAllHealthy) {
        ctx.fillStyle = '#E8F5E9'
        ctx.strokeStyle = '#A5D6A7'
      } else if (summary.hasDisease) {
        ctx.fillStyle = '#FFEBEE'
        ctx.strokeStyle = '#EF9A9A'
      } else {
        ctx.fillStyle = '#F5F5F5'
        ctx.strokeStyle = '#E0E0E0'
      }
      ctx.lineWidth = 1
      this._roundRect(ctx, PADDING, bannerY, CANVAS_W_RPX - PADDING * 2, BANNER_H - 24, 12)
      ctx.fill()
      ctx.stroke()

      var bannerText = summary.isAllHealthy
        ? '本批次水稻状况良好'
        : (summary.hasDisease ? '发现疑似病害：' + summary.diseaseNamesText : '分析完成')
      ctx.fillStyle = '#1A1A1A'
      ctx.font = 'bold 28px PingFang SC'
      ctx.fillText(bannerText, PADDING + 16, bannerY + 42)
      ctx.fillStyle = '#888'
      ctx.font = '22px PingFang SC'
      var subLine = ''
      if (summary.diseaseCount > 0) subLine += '病害 ' + summary.diseaseCount + ' 张  '
      if (summary.healthyCount > 0) subLine += '健康 ' + summary.healthyCount + ' 张  '
      if (summary.invalidCount > 0) subLine += '无效 ' + summary.invalidCount + ' 张  '
      ctx.fillText(subLine + '共 ' + summary.total + ' 张', PADDING + 16, bannerY + 74)

      // ── 结果卡片（串行绘制图片）──
      const drawCards = (cardIndex) => {
        if (cardIndex >= sortedResults.length) {
          // 所有卡片绘制完毕，绘制对应病害判断和底部。
          this._drawPosterJudgmentsAndFooter(ctx, detailBlocks, PADDING, CANVAS_W_RPX,
            HEADER_H + BANNER_H + sortedResults.length * CARD_H, DETAIL_LINE_H, totalH, FOOTER_H)
          // 导出
          wx.canvasToTempFilePath({
            canvas: canvas,
            success: (r) => {
              wx.hideLoading()
              wx.saveImageToPhotosAlbum({
                filePath: r.tempFilePath,
                success: () => {
                  wx.showModal({
                    title: '报告已保存',
                    content: '检测报告已保存至相册，请打开相册分享给农技专家或好友。',
                    showCancel: false,
                    confirmText: '好的',
                    confirmColor: '#2E7D32'
                  })
                },
                fail: () => {
                  wx.hideLoading()
                  wx.showToast({ title: '保存相册失败', icon: 'none', duration: 2000 })
                }
              })
            },
            fail: () => {
              wx.hideLoading()
              wx.showToast({ title: '生成报告失败', icon: 'none', duration: 2000 })
            }
          })
          return
        }

        const r = sortedResults[cardIndex]
        const cardY = HEADER_H + BANNER_H + cardIndex * CARD_H

        // 卡片背景
        var borderColor = r.displayStatus === 'healthy' ? '#2E7D32'
          : r.displayStatus === 'disease' ? '#C62828'
          : r.displayStatus === 'invalid' ? '#9E9E9E' : '#757575'
        ctx.fillStyle = '#FFFFFF'
        this._roundRect(ctx, PADDING, cardY + 8, CANVAS_W_RPX - PADDING * 2, CARD_H - 16, 14)
        ctx.fill()
        ctx.fillStyle = borderColor
        ctx.fillRect(PADDING, cardY + 8, 7, CARD_H - 16)

        // 文字
        ctx.fillStyle = borderColor
        ctx.font = 'bold 32px PingFang SC'
        ctx.fillText(r.predicted_class, PADDING + 172, cardY + 50)
        ctx.fillStyle = '#999'
        ctx.font = '22px PingFang SC'
        ctx.fillText('置信度 ' + r.confidenceText, PADDING + 172, cardY + 86)
        ctx.fillText(r.displayLabel, PADDING + 172, cardY + 116)

        // 图片（若有）
        if (r.imagePath) {
          const img = canvas.createImage()
          img.onload = () => {
            ctx.save()
            this._roundRect(ctx, PADDING + 14, cardY + 16, 140, 140, 10)
            ctx.clip()
            ctx.drawImage(img, PADDING + 14, cardY + 16, 140, 140)
            ctx.restore()
            drawCards(cardIndex + 1)
          }
          img.onerror = () => {
            // 图片加载失败：绘制占位灰块
            ctx.fillStyle = '#EEEEEE'
            this._roundRect(ctx, PADDING + 14, cardY + 16, 140, 140, 10)
            ctx.fill()
            drawCards(cardIndex + 1)
          }
          img.src = r.imagePath
        } else {
          drawCards(cardIndex + 1)
        }
      }

      drawCards(0)
    })
  },

  _posterJudgmentBlocks(results, lineHeight) {
    const names = []
    const blocks = []
    results.forEach(function(result) {
      const name = result.predicted_class
      if (result.displayStatus !== 'disease' || !Object.prototype.hasOwnProperty.call(profiles, name) || names.indexOf(name) >= 0) return
      names.push(name)
      const lines = []
      profiles[name].judgments.forEach(function(judgment, index) {
        let text = JUDGMENT_NUMBERS[index] + ' ' + judgment
        while (text.length) {
          lines.push(text.slice(0, 24))
          text = text.slice(24)
        }
      })
      blocks.push({ name: name, lines: lines, height: 72 + lines.length * lineHeight })
    })
    return blocks
  },

  _drawPosterJudgmentsAndFooter(ctx, blocks, PADDING, CANVAS_W, startY, LINE_H, totalH, FOOTER_H) {
    var y = startY
    blocks.forEach(function(block) {
        ctx.fillStyle = '#EFF8FF'
        ctx.strokeStyle = '#42A5F5'
        ctx.lineWidth = 1
        ctx.fillRect(PADDING, y + 8, CANVAS_W - PADDING * 2, block.height)
        ctx.strokeRect(PADDING, y + 8, CANVAS_W - PADDING * 2, block.height)
        ctx.fillStyle = '#1565C0'
        ctx.font = 'bold 24px PingFang SC'
        ctx.fillText(block.name + ' · 判断要点', PADDING + 14, y + 40)
        ctx.fillStyle = '#37474F'
        ctx.font = '22px PingFang SC'
        block.lines.forEach(function(line, li) {
          ctx.fillText(line, PADDING + 14, y + 68 + li * LINE_H)
        })
        y += block.height + 16
    })

    // 底部水印
    ctx.fillStyle = '#AAAAAA'
    ctx.font = '22px PingFang SC'
    ctx.textAlign = 'center'
    ctx.fillText('稻视界 · 检测记录', CANVAS_W / 2, totalH - FOOTER_H + 42)
    ctx.textAlign = 'left'
  },

  // 绘制圆角矩形路径（辅助函数）
  _roundRect(ctx, x, y, w, h, r) {
    ctx.beginPath()
    ctx.moveTo(x + r, y)
    ctx.lineTo(x + w - r, y)
    ctx.arcTo(x + w, y, x + w, y + r, r)
    ctx.lineTo(x + w, y + h - r)
    ctx.arcTo(x + w, y + h, x + w - r, y + h, r)
    ctx.lineTo(x + r, y + h)
    ctx.arcTo(x, y + h, x, y + h - r, r)
    ctx.lineTo(x, y + r)
    ctx.arcTo(x, y, x + r, y, r)
    ctx.closePath()
  },


  // 微信右上角分享给朋友
  onShareAppMessage: function () {
    return {
      title: '水稻病害AI检测工具',
      path: '/pages/index/index'
    }
  },

  // 微信右上角分享到朋友圈
  onShareTimeline: function () {
    return {
      title: '快来测一测水稻健康状况'
    }
  },

  // Location belongs to the selected photo. Detection never re-acquires GPS.
  onDetect() {
    if (this.data.loading || this.data.selecting || this.data.savingHistory) return

    const images = this.data.images
    if (!images || images.length === 0) {
      wx.showToast({ title: '请先选择图片', icon: 'none', duration: 2000 })
      return
    }

    this._detectionToken = (this._detectionToken || 0) + 1
    this.setData({
      loading: true,
      results: [],
      sortedResults: [],
      summary: { hasResults: false },
      statusText: '检测中，请稍候...',
      errorText: ''
    })

    this._startDetect(images)
  },

  // Execute classification independently of whether a photo is located.
  _startDetect(images) {
    this._historyRevisionAtDetection = historyStore.revision()
    this.setData({ statusText: '检测中，请稍候...' })
    if (MOCK_MODE) {
      this._mockDetectAll(images)
    } else {
      this._realDetectAll(images)
    }
  },

  // 完成检测后更新 sortedResults 和 summary，并异步保存历史
  _finalizeResults(results) {
    const sorted = sortResults(results)
    const summary = computeSummary(results)
    summary.time = formatTime(Date.now())
    if (!this._unloaded) this.setData({
      results: results,
      sortedResults: sorted,
      summary: summary,
      reportScrollTop: 0,
      loading: false,
      savingHistory: true,
      statusText: '',
      posterReady: false   // 重置，等待 _saveToHistory 异步完成后设为 true
    })
    // 异步保存历史（GPS 已内嵌在每个 sortedResult 中）
    this._saveToHistory(sorted, summary)
  },

  // MOCK 模式：模拟逐张检测
  _mockDetectAll(images) {
    const results = []
    let count = 0

    const processNext = () => {
      if (count >= images.length) {
        this._finalizeResults(results)
        return
      }

      const img = images[count]
      const tpl = MOCK_RESULTS_TEMPLATES[count % MOCK_RESULTS_TEMPLATES.length]
      const predicted_class = tpl.predicted_class
      const confidence = tpl.confidence
      const is_valid = tpl.is_valid
      const displayStatus = calcDisplayStatus(predicted_class, is_valid)
      const top3Items = formatTop3(tpl.top3_predictions)
      const showTop3 = (displayStatus === 'disease')

      const result = attachImageLocation({
        displayLabel: '图片 ' + img.index,
        predicted_class: predicted_class,
        confidence: confidence,
        confidenceText: formatConfidence(confidence),
        displayStatus: displayStatus,
        is_valid: is_valid,
        message: tpl.message,
        top3Items: top3Items,
        showTop3: showTop3,
        imagePath: img.path,
        imageIndex: img.index
      }, img)
      results.push(result)
      count++

      setTimeout(processNext, 300)
    }

    setTimeout(processNext, 500)
  },

  // 真实后端模式：逐张上传
  _realDetectAll(images) {
    const results = []
    let count = 0

    const processNext = () => {
      if (count >= images.length) {
        this._finalizeResults(results)
        return
      }

      const img = images[count]
      const currentIndex = count
      count++

      this.setData({
        statusText: '正在分析第 ' + img.index + '/' + images.length + ' 张...'
      })

      wx.uploadFile({
        url: PREDICT_URL,
        filePath: img.path,
        name: FILE_FIELD_NAME,
        success: (res) => {
          const result = attachImageLocation(parseBackendResult(res.data, img.index), img)
          results[currentIndex] = result
        },
        fail: (err) => {
          const result = attachImageLocation(buildFailResult(img.index, '上传失败: ' + (err.errMsg || '网络错误')), img)
          results[currentIndex] = result
        },
        complete: () => {
          processNext()
        }
      })
    }

    processNext()
  }
})
