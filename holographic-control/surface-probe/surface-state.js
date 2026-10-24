(function () {
    'use strict';
    var queue = Promise.resolve(), ticks = 0, activation = null;
    var started = new Date().toISOString(), showRequest = null;
    function save(phase) {
        if (!window.Windows) return;
        var value = {
            version: 3, phase: phase, startedAt: started,
            at: new Date().toISOString(), ticks: ticks,
            hidden: document.hidden, visibilityState: document.visibilityState,
            focused: document.hasFocus(), width: window.innerWidth,
            height: window.innerHeight, activationKind: activation,
            showRequest: showRequest,
            visualVerified: false
        };
        queue = queue.then(function () {
            return Windows.Storage.ApplicationData.current.localFolder.createFileAsync(
                'surface-state.json', Windows.Storage.CreationCollisionOption.replaceExisting
            ).then(function (file) {
                return Windows.Storage.FileIO.writeTextAsync(file, JSON.stringify(value));
            });
        }).catch(function () {});
    }
    function showOwnView() {
        if (showRequest) return;
        showRequest = { attempted: true, viewId: null, returned: null, error: null };
        try {
            var view = Windows.UI.ViewManagement.ApplicationView.getForCurrentView();
            showRequest.viewId = view.id;
            save('show_view_requested');
            Windows.UI.ViewManagement.ApplicationViewSwitcher.tryShowAsStandaloneAsync(view.id).then(function (shown) {
                showRequest.returned = Boolean(shown);
                save('show_view_returned');
            }, function (error) {
                showRequest.error = { message: String(error.message || error), number: error.number || 0 };
                save('show_view_failed');
            });
        } catch (error) {
            showRequest.error = { message: String(error.message || error), number: error.number || 0 };
            save('show_view_unavailable');
        }
    }
    if (window.Windows) {
        try {
            Windows.UI.WebUI.WebUIApplication.addEventListener('activated', function (args) {
                activation = args.kind;
                save('activated');
                showOwnView();
            });
        } catch (_) {}
    }
    document.addEventListener('DOMContentLoaded', function () { save('dom_ready'); });
    document.addEventListener('visibilitychange', function () { save('visibility_changed'); });
    save('script_loaded');
    var timer = setInterval(function () {
        ticks++;
        save('heartbeat');
        if (ticks >= 60) clearInterval(timer);
    }, 1000);
}());
