(function (root) {
    'use strict';
    var W = root.Windows;
    function NativeRuntime() { this.folder = null; this.runId = ''; this.queue = Promise.resolve(); this.camera = null; this.pending = null; }
    NativeRuntime.prototype.hresult = function (e) { return e && typeof e.number === 'number' ? '0x' + (e.number >>> 0).toString(16) : null; };
    NativeRuntime.prototype.deviceFamily = function () { return W.System.Profile.AnalyticsInfo.versionInfo.deviceFamily; };
    NativeRuntime.prototype.loadConfiguration = async function () {
        var file = await W.ApplicationModel.Package.current.installedLocation.getFileAsync('session.json');
        var config = JSON.parse(await W.Storage.FileIO.readTextAsync(file));
        this.nativeSource = config.capture_source === 'native';
        return config;
    };
    NativeRuntime.prototype.open = async function (runId) {
        this.runId = runId;
        var parent = await W.Storage.ApplicationData.current.localFolder.createFolderAsync('single-shot', W.Storage.CreationCollisionOption.openIfExists);
        this.folder = await parent.createFolderAsync(runId, W.Storage.CreationCollisionOption.openIfExists);
    };
    NativeRuntime.prototype.hasAttempted = function () { return W.Storage.ApplicationData.current.localSettings.values['attempt-' + this.runId] === true; };
    NativeRuntime.prototype.reserveAttempt = function () { W.Storage.ApplicationData.current.localSettings.values['attempt-' + this.runId] = true; };
    NativeRuntime.prototype.newId = function () { return 'hl-' + W.Security.Cryptography.CryptographicBuffer.encodeToHexString(W.Security.Cryptography.CryptographicBuffer.generateRandom(16)); };
    NativeRuntime.prototype.artifactFolder = async function () {
        if (!this.nativeSource) return this.folder;
        try {
            var parent = await W.ApplicationModel.Package.current.installedLocation.getFolderAsync('native-shots');
            return await parent.getFolderAsync(this.runId);
        } catch (e) { if ((e.number >>> 0) === 0x80070002 || (e.number >>> 0) === 0x80070003) return null; throw e; }
    };
    NativeRuntime.prototype.readJSON = async function (name) {
        var folder = this.nativeSource && (name === 'capture.json' || name === 'result.json') ? await this.artifactFolder() : this.folder;
        if (!folder) return null;
        var file = await folder.tryGetItemAsync(name);
        return file ? JSON.parse(await W.Storage.FileIO.readTextAsync(file)) : null;
    };
    NativeRuntime.prototype.writeJSON = function (name, value) {
        var self = this, serialized = JSON.stringify(value, null, 2);
        var work = async function () {
            var file = await self.folder.createFileAsync(name + '.tmp', W.Storage.CreationCollisionOption.replaceExisting);
            await W.Storage.FileIO.writeTextAsync(file, serialized);
            await file.moveAsync(self.folder, name, W.Storage.NameCollisionOption.replaceExisting);
        };
        var next = this.queue.then(work, work); this.queue = next.catch(function () {}); return next;
    };
    NativeRuntime.prototype.hashBuffer = function (buffer) {
        var provider = W.Security.Cryptography.Core.HashAlgorithmProvider.openAlgorithm(W.Security.Cryptography.Core.HashAlgorithmNames.sha256);
        return W.Security.Cryptography.CryptographicBuffer.encodeToHexString(provider.hashData(buffer)).toLowerCase();
    };
    NativeRuntime.prototype.photoInfo = function (buffer, requestId) {
        return { request_id: requestId, image_sha256: this.hashBuffer(buffer), image_bytes: buffer.length,
            filename: 'photo.jpg', content_type: 'image/jpeg', captured_at: new Date().toISOString(), camera_closed: true };
    };
    NativeRuntime.prototype.readPhoto = async function (requestId) {
        var folder = await this.artifactFolder();
        if (!folder) return null;
        var file = await folder.tryGetItemAsync('photo.jpg');
        if (!file) return null;
        if (!/^[A-Za-z0-9._-]{1,64}$/.test(requestId || '')) throw root.CaptureCore.error('photo_without_request', '照片恢复需要核对本次编号。');
        var buffer = await W.Storage.FileIO.readBufferAsync(file);
        var meta = await this.readJSON('capture.json');
        var actual = this.photoInfo(buffer, requestId);
        if (meta && (meta.request_id !== requestId || meta.image_sha256 !== actual.image_sha256 || meta.image_bytes !== actual.image_bytes)) {
            throw root.CaptureCore.error('photo_changed', '保存的照片校验不一致。');
        }
        return meta || actual;
    };
    NativeRuntime.prototype.preview = async function () {
        var folder = await this.artifactFolder();
        var file = await folder.getFileAsync('photo.jpg');
        var buffer = await W.Storage.FileIO.readBufferAsync(file);
        return 'data:image/jpeg;base64,' + W.Security.Cryptography.CryptographicBuffer.encodeToBase64String(buffer);
    };
    NativeRuntime.prototype.closeCamera = function () {
        if (this.pending && typeof this.pending.cancel === 'function') { try { this.pending.cancel(); } catch (_) {} }
        this.pending = null;
        if (this.camera) { try { this.camera.close(); } catch (_) {} this.camera = null; }
    };
    NativeRuntime.prototype.cameraOperation = function (operation, timeoutMs) {
        var self = this; this.pending = operation;
        return new Promise(function (resolve, reject) {
            var finished = false;
            var timer = setTimeout(function () {
                if (finished) return; finished = true; self.closeCamera();
                reject(root.CaptureCore.error('camera_timeout', '相机操作超时，已关闭本次相机。'));
            }, timeoutMs);
            operation.then(function (value) {
                if (finished) return; finished = true; clearTimeout(timer); self.pending = null; resolve(value);
            }, function (error) {
                if (finished) return; finished = true; clearTimeout(timer); self.pending = null; reject(error);
            });
        });
    };
    NativeRuntime.prototype.capture = async function (requestId) {
        var stream = new W.Storage.Streams.InMemoryRandomAccessStream(), reader = null;
        try {
            this.camera = new W.Media.Capture.MediaCapture();
            var settings = new W.Media.Capture.MediaCaptureInitializationSettings();
            settings.streamingCaptureMode = W.Media.Capture.StreamingCaptureMode.video;
            // Calling from the foreground JavaScript UI thread preserves the system consent flow.
            await this.cameraOperation(this.camera.initializeAsync(settings), 30000);
            await this.cameraOperation(this.camera.capturePhotoToStreamAsync(W.Media.MediaProperties.ImageEncodingProperties.createJpeg(), stream), 15000);
            this.closeCamera();
            if (!stream.size || stream.size > 7 * 1024 * 1024) throw root.CaptureCore.error('photo_size', '本次照片大小超出限制。');
            reader = new W.Storage.Streams.DataReader(stream.getInputStreamAt(0));
            var count = await reader.loadAsync(stream.size);
            if (count !== stream.size) throw root.CaptureCore.error('photo_read', '本次照片读取不完整。');
            var buffer = reader.readBuffer(count);
            var file = await this.folder.createFileAsync('photo.jpg', W.Storage.CreationCollisionOption.failIfExists);
            await W.Storage.FileIO.writeBufferAsync(file, buffer);
            return this.photoInfo(buffer, requestId);
        } finally {
            this.closeCamera();
            if (reader) reader.close();
            stream.close();
        }
    };
    root.NativeCaptureRuntime = NativeRuntime;
}(window));
