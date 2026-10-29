(function (root) {
  'use strict';
  function ProbeModel(sessionId) {
    this.sessionId = sessionId; this.sequence = 0; this.events = [];
    this.selected = null; this.clicks = { a: 0, b: 0, c: 0 };
    this.heldPointers = {}; this.focus = null; this.text = ''; this.slider = 50;
  }
  ProbeModel.prototype.observe = function (event) {
    var row = { sequence: ++this.sequence, type: event.type, target: event.target,
      at: event.at, elapsed_ms: event.elapsed_ms, trusted: event.trusted === true };
    var fields = ['pointer_id', 'x', 'y', 'button', 'key', 'value'];
    for (var i = 0; i < fields.length; i++) if (event[fields[i]] !== undefined) row[fields[i]] = event[fields[i]];
    if (event.type === 'click' && Object.prototype.hasOwnProperty.call(this.clicks, event.target)) {
      this.clicks[event.target]++; this.selected = event.target;
    }
    if (event.type === 'pointerdown') this.heldPointers[event.pointer_id] = event.target;
    if (event.type === 'pointerup' || event.type === 'pointercancel') delete this.heldPointers[event.pointer_id];
    if (event.type === 'focus') this.focus = event.target;
    if (event.type === 'blur') this.focus = null;
    if (event.type === 'input' && event.target === 'text') this.text = String(event.value);
    if (event.type === 'input' && event.target === 'slider') this.slider = Number(event.value);
    if (event.type === 'windowblur' || event.type === 'visibilityhidden') this.heldPointers = {};
    this.events.push(row); if (this.events.length > 500) this.events.shift();
    return row;
  };
  ProbeModel.prototype.snapshot = function () {
    return JSON.parse(JSON.stringify({ schema_version: 1, version: '1.0.0.0', session_id: this.sessionId,
      sequence: this.sequence, selected: this.selected, clicks: this.clicks, held_pointers: this.heldPointers,
      focus: this.focus, text: this.text, slider: this.slider, events: this.events }));
  };
  if (typeof module !== 'undefined' && module.exports) module.exports = ProbeModel;
  else root.ProbeModel = ProbeModel;
}(this));
