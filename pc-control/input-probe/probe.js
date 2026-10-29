(function () {
  'use strict';
  var model = new ProbeModel(Date.now().toString(36) + '-' + Math.random().toString(36).slice(2));
  var begun = performance.now(), pending = false, writing = false, dirty = false;
  function byId(id) { return document.getElementById(id); }
  function save() {
    if (writing) { dirty = true; return; }
    if (typeof Windows === 'undefined') { byId('storage').textContent = '浏览器预览：没有设备存储证据'; return; }
    writing = true; dirty = false;
    var snapshot = model.snapshot(), text = JSON.stringify(snapshot);
    Windows.Storage.ApplicationData.current.localFolder.createFileAsync('input-probe-state.json', Windows.Storage.CreationCollisionOption.replaceExisting).then(function (file) {
      return Windows.Storage.FileIO.writeTextAsync(file, text);
    }).then(function () { writing = false; byId('storage').textContent = '已保存事件 ' + snapshot.sequence + ' · LocalState/input-probe-state.json'; if (dirty) save(); }, function (error) {
      writing = false; byId('storage').textContent = '保存失败：' + (error.number || error.name || 'unknown');
    });
  }
  function render() {
    byId('selection').textContent = model.selected ? '已选择 ' + model.selected.toUpperCase() + ' · A=' + model.clicks.a + ' B=' + model.clicks.b + ' C=' + model.clicks.c : '尚未选择';
    byId('focus').textContent = '焦点：' + (model.focus || '无');
    byId('slider-value').textContent = String(model.slider);
    byId('summary').textContent = '事件 ' + model.sequence + ' · 按住 ' + Object.keys(model.heldPointers).length;
    byId('events').textContent = model.events.slice(-5).map(function (e) { return e.sequence + ' ' + e.type + ' ' + e.target + ' trusted=' + e.trusted; }).join('\n');
  }
  function record(type, target, event, value) {
    var row = { type: type, target: target, at: new Date().toISOString(), elapsed_ms: Math.round(performance.now() - begun), trusted: event && event.isTrusted === true };
    if (event) { if (event.pointerId !== undefined) row.pointer_id = event.pointerId; if (event.clientX !== undefined) { row.x = event.clientX; row.y = event.clientY; } if (event.button !== undefined) row.button = event.button; if (event.key !== undefined) row.key = event.key; }
    if (value !== undefined) row.value = value;
    model.observe(row); render();
    if (!pending) { pending = true; setTimeout(function () { pending = false; save(); }, 100); }
  }
  ['a', 'b', 'c'].forEach(function (name) { byId('target-' + name).addEventListener('click', function (e) { record('click', name, e); }); });
  ['text', 'slider', 'drag-surface'].forEach(function (name) {
    var element = byId(name);
    ['focus', 'blur', 'keydown', 'keyup', 'pointerdown', 'pointerup', 'pointercancel'].forEach(function (type) { element.addEventListener(type, function (e) { record(type, name, e); }); });
    element.addEventListener('input', function (e) { record('input', name, e, element.value); });
  });
  var drag = byId('drag-surface');
  drag.addEventListener('pointerdown', function (e) { try { drag.setPointerCapture(e.pointerId); } catch (_) {} });
  drag.addEventListener('pointermove', function (e) { if (Object.prototype.hasOwnProperty.call(model.heldPointers, e.pointerId)) { byId('drag-marker').style.left = Math.max(0, Math.min(drag.clientWidth - 35, e.clientX - drag.getBoundingClientRect().left)) + 'px'; record('pointermove', 'drag-surface', e); } });
  window.addEventListener('blur', function (e) { record('windowblur', 'window', e); });
  document.addEventListener('visibilitychange', function (e) { if (document.hidden) record('visibilityhidden', 'window', e); });
  byId('session').textContent = '会话 ' + model.sessionId + ' · 独立测试应用';
  record('started', 'application', null);
}());
