// Align custom page titles with the native capsule instead of reserving a tall hero.
function headerLayout(api) {
  let info = {}
  try { info = api.getWindowInfo ? api.getWindowInfo() : api.getSystemInfoSync() } catch (error) { /* Use safe defaults. */ }
  const width = Number(info && info.windowWidth) || 375
  const statusBarHeight = Number(info && info.statusBarHeight) || 24
  const fallback = { headerTopInset: statusBarHeight + 6, headerNavHeight: 32, headerRightInset: 112 }
  try {
    const menu = api.getMenuButtonBoundingClientRect()
    if (menu && Number.isFinite(menu.top) && menu.top >= statusBarHeight &&
        Number.isFinite(menu.height) && menu.height > 0 && Number.isFinite(menu.left) && menu.left > 0) {
      return { headerTopInset: menu.top, headerNavHeight: menu.height,
        headerRightInset: Math.max(100, width - menu.left + 12) }
    }
  } catch (error) { /* The capsule is not available in every runtime. */ }
  return fallback
}

module.exports = { headerLayout }
