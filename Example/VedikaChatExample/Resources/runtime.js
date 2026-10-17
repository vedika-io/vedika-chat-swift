// Vedika chat example page bridge stub.
//
// The real bundled chat calls `window.webkit.messageHandlers.vedika.postMessage(...)`
// here. This stub does the same so the host-side bridge wiring can be
// verified end-to-end on the example without a real bundle.
(function () { "use strict";
    window.__VEDIKA_NATIVE__ = true;
})();
