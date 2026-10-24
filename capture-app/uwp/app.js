(function () {
    'use strict';
    var runtime, controller, previewShown = false, previewTask = null, renderGeneration = 0, rendering = false, timer;
    // Keep a modal activation operation alive while showing the result in this app.
    if (window.Windows) Windows.UI.WebUI.WebUIApplication.addEventListener('activated', function (event) {
        var args = event.detail || event;
        if (args.kind === Windows.ApplicationModel.Activation.ActivationKind.protocolForResults) window.captureActivationOperation = args.protocolForResultsOperation;
    });
    function el(name) { return document.getElementById(name); }
    function message(title, text, kind) { el('result-title').textContent = title; el('result-message').textContent = text; el('result-panel').setAttribute('data-state', kind || 'idle'); }
    async function display(state, result) {
        var generation = ++renderGeneration;
        el('run-label').textContent = state.run_id;
        el('capture-button').disabled = state.phase !== 'ready';
        el('cancel-button').hidden = true;
        el('result-panel').setAttribute('aria-busy', state.phase === 'initializing_camera' ? 'true' : 'false');
        if (state.photo && !previewShown) {
            try {
                if (!previewTask) previewTask = runtime.preview();
                var preview = await previewTask;
                if (generation !== renderGeneration) return;
                previewShown = true; el('photo').src = preview; el('photo').hidden = false; el('photo-label').hidden = false; el('photo-placeholder').hidden = true;
            } catch (_) {
                if (generation !== renderGeneration) return;
                el('capture-hint').textContent = '照片已保存，当前预览无法显示。';
            }
        }
        if (generation !== renderGeneration) return;
        if (state.phase === 'ready') {
            el('camera-status').textContent = '相机未开启';
            message('准备拍摄', '对准目标并保持稳定，按一次“拍摄并识别”。');
        } else if (state.phase === 'waiting_for_capture') {
            el('camera-status').textContent = '等待单张照片';
            message('等待本次拍摄', '请对准拍摄对象并保持 USB 连接，电脑正在协调眼镜的单次拍摄。');
            el('capture-hint').textContent = '本页面只接收本次新照片与结果，不会另行拍摄。';
        } else if (state.phase === 'initializing_camera') {
            el('camera-status').textContent = '相机准备中';
            message('正在拍摄', '若系统询问相机权限，请允许本应用使用相机。');
        } else if (state.phase === 'waiting_for_result') {
            el('camera-status').textContent = '相机已关闭';
            el('capture-hint').textContent = '本张照片已保存。请保持 USB 连接，电脑将送交识别并传回结果。';
            message('等待传回结果', '正在处理本张照片，无需再次拍摄。');
        } else if ((state.phase === 'result_received' || state.phase === 'result_rendered') && result) {
            el('camera-status').textContent = '相机已关闭';
            message(result.is_valid ? result.predicted_class : '未确认识别', result.is_valid ? (result.message || '候选结果，请结合叶片情况复核。') : (result.message || '模型未确认本张照片，请现场复核。'), result.is_valid ? 'accepted' : 'rejected');
            el('score').textContent = (result.confidence * 100).toFixed(1) + '%'; el('score-row').hidden = false;
            el('result-reference').textContent = '照片 ' + state.photo.image_sha256.slice(0, 12) + ' · 结果 ' + result.capture_evidence.prediction_id;
            el('result-reference').hidden = false;
            el('capture-hint').textContent = '本张照片及对应结果已收到，研究验证完成。';
            if (state.phase === 'result_received' && !rendering) {
                rendering = true;
                requestAnimationFrame(function () { requestAnimationFrame(function () {
                    controller.acknowledgeRendered().catch(showFailure).then(function () { rendering = false; });
                }); });
            }
        } else if (state.phase === 'camera_error' || state.phase === 'camera_attempt_finished') {
            el('camera-status').textContent = '相机已关闭';
            message('本次拍摄未完成', '请保留 USB 连接，由电脑核对相机权限、前台状态和本次日志。应用不会自动重复拍摄。', 'error');
            el('capture-hint').textContent = '状态：' + (state.error_code || '') + (state.hresult ? ' ' + state.hresult : '');
        } else if (state.phase === 'result_error') {
            message('结果校验失败', '本张照片仍保存在应用内。请保留 USB 连接，由电脑核对传回结果。', 'error');
        }
    }
    function showFailure(error) { message('应用准备未完成', (error && error.message) || '请保留 USB 连接并查看本次日志。', 'error'); }
    async function start() {
        if (!window.Windows) { showFailure(new Error('本页面需要在眼镜已安装的应用内运行。')); return; }
        runtime = new window.NativeCaptureRuntime();
        controller = new window.CaptureCore.Controller(runtime, function (state, result) { display(state, result).catch(showFailure); });
        var config = await runtime.loadConfiguration();
        await controller.initialize(config);
        el('capture-button').addEventListener('click', function () { controller.capture().catch(showFailure); });
        timer = setInterval(function () { controller.checkResult().catch(showFailure); }, 1000);
        if (config.autocapture === true && controller.state.phase === 'ready') {
            el('session-note').textContent = '本次联调已安排一次拍摄，请对准目标并保持稳定。'; el('session-note').hidden = false;
            setTimeout(function () { controller.capture().catch(showFailure); }, 2000);
        }
        window.addEventListener('beforeunload', function () { clearInterval(timer); runtime.closeCamera(); });
        Windows.UI.WebUI.WebUIApplication.addEventListener('suspending', function () { runtime.closeCamera(); });
    }
    start().catch(showFailure);
}());
