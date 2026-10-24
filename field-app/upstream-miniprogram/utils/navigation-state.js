const historyStore = require('./history-store')

// Session-only reading progress. No report or location data is duplicated in storage.
let historyReport = null

function rememberHistoryReport(value) {
  if (!value || value.id == null) return
  historyReport = { id: value.id, scrollTop: Math.max(0, Number(value.scrollTop) || 0),
    expandedImages: (value.expandedImages || []).map(String) }
}

function getHistoryReport(id) {
  if (!historyReport || String(historyReport.id) !== String(id)) return null
  return Object.assign({}, historyReport, { expandedImages: historyReport.expandedImages.slice() })
}

function forgetHistoryReport(id) {
  if (id == null || (historyReport && String(historyReport.id) === String(id))) historyReport = null
}

function historyDestination(api) {
  if (historyReport) {
    try {
      if (historyStore.load(api).some(function(record) { return String(record.id) === String(historyReport.id) })) {
        return '/pages/index/index?historyId=' + encodeURIComponent(historyReport.id) + '&resume=1'
      }
      historyReport = null
    } catch (error) { /* Let the list show its existing read-error state. */ }
  }
  return '/pages/history/history'
}

module.exports = { rememberHistoryReport, getHistoryReport, forgetHistoryReport, historyDestination }
