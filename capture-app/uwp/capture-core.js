(function (root, factory) {
    'use strict';
    var api = factory();
    if (typeof module === 'object' && module.exports) module.exports = api;
    else root.CaptureCore = api;
}(typeof window === 'object' ? window : this, function () {
    'use strict';
    function fail(code, message) { var e = new Error(message); e.code = code; return e; }
    function config(value) {
        if (!value || !/^[A-Za-z0-9_-]{1,64}$/.test(value.run_id || '')) throw fail('configuration', '本次会话编号无效。');
        // This build uses the already paired USB channel. The eye needs no cloud credential.
        if (value.transport !== 'usb') throw fail('configuration', '本版本需要 USB 连接电脑。');
        return { run_id: value.run_id, transport: 'usb', autocapture: value.autocapture === true,
            capture_source: value.capture_source === 'native' ? 'native' : 'ui' };
    }
    function verifyResult(payload, runId, photo) {
        var proof = payload && payload.capture_evidence;
        if (!photo || !proof || proof.run_id !== runId || proof.request_id !== photo.request_id ||
            typeof proof.image_sha256 !== 'string' || proof.image_sha256.toLowerCase() !== photo.image_sha256 ||
            !/^[A-Za-z0-9._-]{1,128}$/.test(proof.prediction_id || '')) {
            throw fail('result_mismatch', '结果与本次照片不一致，已停止显示。');
        }
        if (typeof payload.predicted_class !== 'string' || !payload.predicted_class.trim() ||
            typeof payload.is_valid !== 'boolean' || typeof payload.confidence !== 'number' ||
            !isFinite(payload.confidence) || payload.confidence < 0 || payload.confidence > 1) {
            throw fail('result_format', '识别结果格式无效。');
        }
        return payload;
    }
    function Controller(runtime, onChange) {
        this.runtime = runtime; this.onChange = onChange || function () {};
        this.busy = false; this.state = null; this.configuration = null; this.result = null;
    }
    Controller.prototype.publish = async function (phase, extra) {
        var next = Object.assign({}, this.state || {}, extra || {}, {
            schema_version: 1, run_id: this.configuration.run_id, phase: phase,
            transport: 'usb', runtime: 'winrt-media-capture', updated_at: new Date().toISOString()
        });
        this.state = next;
        await this.runtime.writeJSON('state.json', next);
        this.onChange(next, this.result);
    };
    Controller.prototype.initialize = async function (value) {
        this.configuration = config(value);
        await this.runtime.open(this.configuration.run_id);
        var previous = await this.runtime.readJSON('state.json');
        if (previous && previous.run_id !== this.configuration.run_id) throw fail('state_mismatch', '本地会话不一致。');
        this.state = previous || {};
        var metadata = await this.runtime.readJSON('capture.json');
        var photo = await this.runtime.readPhoto((metadata && metadata.request_id) || this.state.request_id);
        if (photo) {
            await this.runtime.writeJSON('capture.json', photo);
            await this.publish('waiting_for_result', { request_id: photo.request_id, photo: photo });
            await this.checkResult();
        } else if (this.configuration.capture_source === 'native') {
            await this.publish('waiting_for_capture', { device_family: this.runtime.deviceFamily() });
        } else if (this.runtime.hasAttempted()) {
            // A crash or camera failure must never silently trigger another exposure.
            await this.publish('camera_attempt_finished', { error_code: 'attempt_already_reserved' });
        } else await this.publish('ready', { device_family: this.runtime.deviceFamily() });
        return this.state;
    };
    Controller.prototype.capture = async function () {
        if (this.busy || !this.state || this.configuration.capture_source === 'native' || this.state.photo || this.runtime.hasAttempted()) return false;
        this.busy = true;
        try {
            var requestId = this.runtime.newId();
            this.runtime.reserveAttempt();
            await this.publish('initializing_camera', { request_id: requestId });
            var photo = await this.runtime.capture(requestId);
            await this.runtime.writeJSON('capture.json', photo);
            await this.publish('waiting_for_result', { photo: photo, error_code: null });
            return true;
        } catch (e) {
            await this.publish('camera_error', { error_code: e.code || 'camera_failed', hresult: this.runtime.hresult(e) });
            return false;
        } finally { this.busy = false; }
    };
    Controller.prototype.checkResult = async function () {
        if (!this.state || this.busy || this.state.phase === 'result_rendered') return false;
        this.busy = true;
        try {
            if (!this.state.photo && this.configuration.capture_source === 'native') {
                var metadata = await this.runtime.readJSON('capture.json');
                if (!metadata) return false;
                var externalPhoto = await this.runtime.readPhoto(metadata.request_id);
                if (!externalPhoto) return false;
                await this.publish('waiting_for_result', { request_id: externalPhoto.request_id, photo: externalPhoto });
            }
            if (!this.state.photo) return false;
            var incoming = await this.runtime.readJSON('result.json');
            if (!incoming) return false;
            this.result = verifyResult(incoming, this.configuration.run_id, this.state.photo);
            await this.publish('result_received', { prediction_id: incoming.capture_evidence.prediction_id });
            // The UI acknowledges rendering only after two animation frames.
            return true;
        } catch (e) {
            await this.publish('result_error', { error_code: e.code || 'result_read_failed' });
            return false;
        } finally { this.busy = false; }
    };
    Controller.prototype.acknowledgeRendered = async function () {
        if (!this.result || this.state.phase !== 'result_received') return false;
        await this.publish('result_rendered', { result: {
            prediction_id: this.result.capture_evidence.prediction_id,
            request_id: this.result.capture_evidence.request_id,
            image_sha256: this.result.capture_evidence.image_sha256,
            accepted: this.result.is_valid, class_name: this.result.predicted_class,
            confidence: this.result.confidence, rendered_at: new Date().toISOString()
        } });
        return true;
    };
    return { Controller: Controller, validateConfiguration: config, verifyResult: verifyResult, error: fail };
}));
