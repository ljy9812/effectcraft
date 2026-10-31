import { webview } from '@kit.ArkWeb';
import { picker, fileIo as fs } from '@kit.CoreFileKit';
import { util } from '@kit.ArkTS';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { common } from '@kit.AbilityKit';

const TAG: string = 'EffectCraft';
const MAIN_URL: string = 'https://local.effectcraft/index.html';
const URL_PREFIX: string = 'https://local.effectcraft/';
const RAW_PREFIX: string = 'web/';
const CHUNK_SIZE: number = 262144; // 256 KiB per message port frame (base64)
const URL_PATTERN: string = 'https://local.effectcraft/*';
// FORCE_EN: apps whose wasm auto-detects UI language from navigator.languages
// resolve zh on this device but ship no CJK glyphs, so their whole UI turns to
// tofu (vectorcraft/effectcraft/cadcraft class). true = handleRequest rewrites
// index.html at serve time, injecting a classic <script> right after <head>
// that pins navigator.languages/language to ['en'] — classic scripts execute
// during parse, before the trunk-loader module script (deferred) reads them,
// so English applies from the very first launch. Strictly better than the
// four-suite-era storage-key forcing: that only took effect on the second
// launch and polluted shared-bundle localStorage across app swaps. Apps that
// render zh natively (lightcraft: ships zh_hans.otf) must keep this false.
const FORCE_EN: boolean = false;

interface ExportMsg {
  t: string;
  name?: string;
  data?: string;
}

// Injected before page scripts run:
// 1. receive the MessageChannel port handed over by ArkTS (window.__pc_port)
// 2. intercept <a download href="blob:..."> clicks and stream the blob through
//    the port in chunks. Two interception paths, because the apps differ:
//    - some wasms attach their download anchor to the DOM before clicking, so
//      the click bubbles and the document listener (path 1) sees it.
//    - other wasms (pdfcraft/wordcraft/gridcraft/deckcraft family) create the
//      anchor, set download/href and click it WITHOUT appending — the click
//      event of a detached node never propagates to document, so no document
//      listener can see it. Desktop Chrome still runs the download activation
//      for a detached anchor (which is why upstream never noticed); ArkWeb
//      does nothing at all. Path 2 overrides
//      HTMLAnchorElement.prototype.click to catch programmatic clicks on
//      detached (and attached) anchors.
//    This template ships the minimal proven configuration (dual-path hook,
//    no savepicker neuter). Before building a new app, pre-scan the DECOMPRESSED
//    wasm (gzip parts hide strings!) and extend per the config matrix from the
//    document-suite rounds:
//    - wasm contains showSaveFilePicker/createWritable/suggestedName
//      → add the savepicker neuter block (wordcraft W1 fix) to this script
//    - wasm auto-detects UI language from navigator.languages at init and has
//      no CJK glyphs → set FORCE_EN above to true (pdfcraft P2 fix, v2:
//      serve-time navigator pin, vectorcraft/effectcraft/cadcraft class)
//    - wasm has a font_store channel ("no stored fonts" string present)
//      → a FONT_SEED injection is possible (wordcraft W2)
const START_SCRIPT: string = `(function() {
  if (window.__pc_hook) { return; }
  window.__pc_hook = true;
  console.log('[pc] hook installed');
  function pcSend(href, name, src) {
    var port = window.__pc_port;
    console.log('[pc] download click: ' + name + ' port=' + (port ? 'yes' : 'NO') + (src ? ' [' + src + ']' : ''));
    if (!port) { return; }
    fetch(href).then(function(r) { return r.blob(); }).then(function(b) {
      console.log('[pc] blob fetched: ' + b.size + ' B');
      var fr = new FileReader();
      fr.onload = function() {
        var du = String(fr.result);
        var b64 = du.substring(du.indexOf(',') + 1);
        port.postMessage(JSON.stringify({ t: 'begin', name: name, total: Math.ceil(b64.length / 262144) }));
        var i = 0;
        while (i * 262144 < b64.length) {
          port.postMessage(JSON.stringify({ t: 'chunk', i: i, data: b64.substr(i * 262144, 262144) }));
          i++;
        }
        port.postMessage(JSON.stringify({ t: 'end' }));
      };
      fr.onerror = function() {};
      fr.readAsDataURL(b);
    }).catch(function() { console.log('[pc] blob fetch failed'); });
  }
  window.addEventListener('message', function(e) {
    if (e.ports && e.ports.length > 0) {
      window.__pc_port = e.ports[0];
      console.log('[pc] port received');
      // EC-7 probe channel: {t:'eval', s:<js source>} from ArkTS -> eval in
      // page, result via console.log('[ec-probe] port-eval: ...') -> hilog.
      // Secondary to runJavaScript (a differential between the two delivery
      // paths is itself diagnostic if one lives and the other dies).
      try {
        window.__pc_port.onmessage = function(ev) {
          var m;
          try { m = JSON.parse(ev.data); } catch (err) { return; }
          if (m && m.t === 'eval' && m.s) {
            try {
              var r = eval(m.s);
              var s;
              try { s = JSON.stringify(r); } catch (e2) { s = String(r); }
              console.log('[ec-probe] port-eval: ' + s);
            } catch (e3) {
              console.log('[ec-probe] port-eval-error: ' + String(e3));
            }
          }
        };
        window.__pc_port.start();
      } catch (e4) {}
    }
  });
  // Path 1: real user clicks on attached a[download] anchors.
  document.addEventListener('click', function(e) {
    var t = e.target;
    if (!t || !t.closest) { return; }
    var a = t.closest('a[download]');
    if (!a) { return; }
    var href = a.getAttribute('href') || '';
    if (href.indexOf('blob:') !== 0) { return; }
    e.preventDefault();
    e.stopPropagation();
    pcSend(href, a.getAttribute('download') || 'export.bin', 'doc');
  }, true);
  // Path 2: programmatic .click() — including detached anchors.
  var origClick = HTMLAnchorElement.prototype.click;
  if (!origClick.__pc_patched) {
    var patched = function() {
      try {
        var href = this.getAttribute('href') || '';
        var name = this.getAttribute('download');
        if (name && href.indexOf('blob:') === 0 && window.__pc_port) {
          pcSend(href, name, 'proto');
          return; // swallow: the native activation is useless in ArkWeb anyway
        }
      } catch (e) {}
      return origClick.apply(this, arguments);
    };
    try { Object.defineProperty(patched, '__pc_patched', { value: true }); } catch (e) {}
    HTMLAnchorElement.prototype.click = patched;
  }
})();`;

// EC-7 probe battery: one tap on the floating PROBE button runs this in the
// page via runJavaScript; every result line goes to console.log('[ec-probe] ')
// which surfaces in hilog. The battery settles the DOM-layer vs wasm-layer
// question in one shot: element stacks at three points (DOM overlay?),
// canvas census (still there?), big-overlay census (fullscreen dialog?),
// #device-lost check, input/agent census, global key scan, and installs
// persistent capture-phase event listeners so the NEXT physical touch tells
// us whether events reach the page at all. rAF + setTimeout liveness probes
// close the loop.
const PROBE_SCRIPT: string = `(function() {
  function L(k, v) {
    try { console.log('[ec-probe] ' + k + ': ' + (typeof v === 'string' ? v : JSON.stringify(v))); }
    catch (e) { console.log('[ec-probe] ' + k + ': (unprintable)'); }
  }
  L('begin', {w: innerWidth, h: innerHeight, dpr: devicePixelRatio, vis: document.visibilityState, focus: document.hasFocus()});
  try {
    var pts = [[innerWidth / 2, innerHeight / 2], [innerWidth / 2, 40], [40, 40]];
    for (var p = 0; p < pts.length; p++) {
      var els = document.elementsFromPoint(pts[p][0], pts[p][1]) || [];
      var names = [];
      for (var i = 0; i < els.length && i < 8; i++) {
        var el = els[i];
        names.push(el.tagName + (el.id ? '#' + el.id : '') + (typeof el.className === 'string' && el.className ? '.' + el.className.split(' ')[0] : ''));
      }
      L('stack@' + pts[p][0].toFixed(0) + ',' + pts[p][1].toFixed(0), names);
    }
  } catch (e) { L('stack-err', String(e)); }
  try {
    var cs = document.querySelectorAll('canvas');
    var info = [];
    for (var i = 0; i < cs.length && i < 8; i++) {
      var r = cs[i].getBoundingClientRect();
      info.push(cs[i].width + 'x' + cs[i].height + ' at ' + r.left.toFixed(0) + ',' + r.top.toFixed(0) + ' ' + r.width.toFixed(0) + 'x' + r.height.toFixed(0));
    }
    L('canvases', info);
  } catch (e) { L('canvas-err', String(e)); }
  try {
    var ov = [];
    var all = document.querySelectorAll('body *');
    var vw = innerWidth * innerHeight;
    for (var i = 0; i < all.length && ov.length < 12; i++) {
      var el = all[i];
      var st = null;
      try { st = getComputedStyle(el); } catch (e2) {}
      if (!st || st.display === 'none' || st.visibility === 'hidden' || st.opacity === '0') { continue; }
      var r = el.getBoundingClientRect();
      if (r.width * r.height > vw * 0.3) {
        ov.push(el.tagName + (el.id ? '#' + el.id : '') + ' ' + r.width.toFixed(0) + 'x' + r.height.toFixed(0) + ' z=' + st.zIndex + ' pe=' + st.pointerEvents);
      }
    }
    L('big-overlays', ov);
  } catch (e) { L('overlay-err', String(e)); }
  try {
    var dl = document.getElementById('device-lost');
    L('device-lost', dl ? 'PRESENT ' + getComputedStyle(dl).display + '/' + getComputedStyle(dl).visibility : 'absent');
  } catch (e) { L('dl-err', String(e)); }
  try {
    var inputs = document.querySelectorAll('input');
    var a = [];
    for (var i = 0; i < inputs.length && i < 5; i++) {
      a.push(inputs[i].type + (inputs[i].id ? '#' + inputs[i].id : '') + ' len=' + (inputs[i].value || '').length + ' focus=' + (document.activeElement === inputs[i]));
    }
    L('inputs', a);
    L('active-el', document.activeElement ? (document.activeElement.tagName + (document.activeElement.id ? '#' + document.activeElement.id : '')) : 'none');
  } catch (e) { L('inputs-err', String(e)); }
  try { L('hook', { pc_hook: !!window.__pc_hook, pc_port: !!window.__pc_port, ec_evts: !!window.__ec_evts }); } catch (e) {}
  try {
    var k = [];
    for (var n in window) { if (/audio|ctx|host|eff|wasm/i.test(n)) { k.push(n); } }
    L('win-keys', k.slice(0, 24));
  } catch (e) { L('keys-err', String(e)); }
  if (!window.__ec_evts) {
    window.__ec_evts = true;
    var evts = ['pointerdown', 'pointerup', 'click', 'touchstart', 'touchend', 'keydown', 'wheel'];
    for (var j = 0; j < evts.length; j++) {
      (function(t) {
        window.addEventListener(t, function(e) {
          try {
            console.log('[ec-probe] EVT ' + t + ' x=' + (e.clientX !== undefined ? e.clientX.toFixed(0) : '-') + ' y=' + (e.clientY !== undefined ? e.clientY.toFixed(0) : '-') + ' tgt=' + (e.target && e.target.tagName ? e.target.tagName : String(e.target)));
          } catch (err) {}
        }, true);
      })(evts[j]);
    }
    L('listeners', 'installed - touch the screen now, arrivals will log');
  } else {
    L('listeners', 'already installed');
  }
  try {
    requestAnimationFrame(function(ts) { console.log('[ec-probe] rAF alive ts=' + ts); });
    setTimeout(function() { console.log('[ec-probe] setTimeout alive'); }, 0);
  } catch (e) { L('rAF-err', String(e)); }
  try {
    var tail = [];
    var c = document.body ? document.body.children : [];
    for (var i = Math.max(0, c.length - 6); i < c.length; i++) { tail.push(c[i].tagName + (c[i].id ? '#' + c[i].id : '')); }
    L('body-tail', tail);
  } catch (e) {}
  // Discriminator: dispatch a synthetic pointerdown on the canvas and watch
  // whether it BUBBLES to document. eframe's canvas pointerdown handler calls
  // stop_propagation() when it runs (even on failure? no - only when the
  // runner lock was acquired, the stop is inside the closure body). So:
  // bubbleReachedDoc=true  -> eframe handler did NOT run its body (try_lock
  //                          failed: panic/destroyed, or listener unsubscribed)
  // bubbleReachedDoc=false -> handler ran and swallowed the event -> the
  //                          block is deeper, inside egui's event processing.
  try {
    var cv = document.getElementById('effectcraft_canvas');
    var got = false;
    var h = function(e) { got = true; };
    document.addEventListener('pointerdown', h, false);
    var ev = new PointerEvent('pointerdown', { bubbles: true, cancelable: true, clientX: 550, clientY: 300, pointerId: 1, pointerType: 'touch', isPrimary: true, button: 0, buttons: 1 });
    cv.dispatchEvent(ev);
    document.removeEventListener('pointerdown', h, false);
    L('synthetic-pd', { bubbleReachedDoc: got });
  } catch (e) { L('synthetic-err', String(e)); }
  L('end', 'battery done');
})();`;

function mimeFor(path: string): string {
  const dot: number = path.lastIndexOf('.');
  if (dot < 0) {
    return 'application/octet-stream';
  }
  switch (path.substring(dot).toLowerCase()) {
    case '.html':
    case '.htm':
      return 'text/html';
    case '.js':
      return 'text/javascript';
    case '.css':
      return 'text/css';
    case '.wasm':
      return 'application/wasm';
    case '.txt':
      return 'text/plain';
    case '.json':
      return 'application/json';
    case '.otf':
      return 'font/otf';
    case '.ttf':
      return 'font/ttf';
    case '.png':
      return 'image/png';
    case '.jpg':
    case '.jpeg':
      return 'image/jpeg';
    case '.svg':
      return 'image/svg+xml';
    case '.ico':
      return 'image/x-icon';
    default:
      return 'application/octet-stream';
  }
}

@Entry
@Component
struct Index {
  controller: webview.WebviewController = new webview.WebviewController();
  private sendPort: webview.WebMessagePort | null = null;
  private recvPort: webview.WebMessagePort | null = null;
  private exportName: string = '';
  private exportChunks: string[] = [];
  // EC-7 probe: custom JS entry dialog (results flow to hilog via [ec-probe]).
  @State evalOpen: boolean = false;
  @State evalText: string = '';

  private toast(msg: string): void {
    this.getUIContext().getPromptAction().showToast({ message: msg });
  }

  // EC-7 probe battery — see PROBE_SCRIPT above. The runJavaScript promise
  // resolution is itself a liveness probe: a blocked page JS loop never runs
  // the script, so neither the promise nor any [ec-probe] line appears.
  private runProbe(): void {
    this.controller.runJavaScript(PROBE_SCRIPT)
      .then(() => hilog.info(0x0000, TAG, 'probe battery executed (JS loop ALIVE - promise resolved)'))
      .catch((e: BusinessError) => hilog.warn(0x0000, TAG, 'probe battery failed: ' + e.code));
    this.toast('探针已派发，结果看 hilog [ec-probe]');
  }

  // EC-7 custom eval: dual delivery. runJavaScript is the primary path (main
  // world, proven [pc] console surface); the message port is the secondary
  // (page-side onmessage handler from START_SCRIPT). Both wrap the source in
  // try/catch and log through [ec-probe].
  private evalInPage(js: string): void {
    if (js.length === 0) {
      return;
    }
    const wrapped: string = '(function(){ try { var r = eval(' + JSON.stringify(js) +
      '); var s; try { s = JSON.stringify(r); } catch (e2) { s = String(r); }' +
      " console.log('[ec-probe] eval: ' + s); } catch (e) { console.log('[ec-probe] eval-error: ' + String(e)); } })()";
    this.controller.runJavaScript(wrapped)
      .then(() => hilog.info(0x0000, TAG, 'eval dispatched (runJavaScript resolved)'))
      .catch((e: BusinessError) => hilog.warn(0x0000, TAG, 'eval dispatch failed: ' + e.code));
    try {
      this.recvPort?.postMessageEvent(JSON.stringify({ t: 'eval', s: js }));
    } catch (e) {
      hilog.warn(0x0000, TAG, 'eval port post failed');
    }
  }

  // F7 fix: the shell only serves the virtual source, so page links to the
  // outside web used to 404 silently (dead click). Hand external navigations
  // to the system browser instead.
  private openExternal(url: string): void {
    try {
      const context = getContext(this) as common.UIAbilityContext;
      context.openLink(url, { appLinkingOnly: false })
        .then(() => hilog.info(0x0000, TAG, 'external link opened: ' + url))
        .catch((e: BusinessError) => hilog.warn(0x0000, TAG, 'openLink failed: ' + e.code + ' ' + url));
    } catch (e) {
      hilog.warn(0x0000, TAG, 'openLink threw: ' + url);
    }
  }

  private notFound(path: string): WebResourceResponse {
    const resp: WebResourceResponse = new WebResourceResponse();
    resp.setResponseData('404 Not Found: ' + path);
    resp.setResponseMimeType('text/plain');
    resp.setResponseEncoding('utf-8');
    resp.setResponseCode(404);
    resp.setReasonMessage('Not Found');
    resp.setResponseIsReady(true);
    return resp;
  }

  // Map https://local.effectcraft/<path> to rawfile web/<path>.
  private handleRequest(url: string): WebResourceResponse {
    if (!url.startsWith(URL_PREFIX)) {
      return this.notFound(url);
    }
    let path: string = url.substring(URL_PREFIX.length);
    const q: number = path.indexOf('?');
    if (q >= 0) {
      path = path.substring(0, q);
    }
    const h: number = path.indexOf('#');
    if (h >= 0) {
      path = path.substring(0, h);
    }
    if (path.length === 0) {
      path = 'index.html';
    }
    if (path.includes('..') || !/^[A-Za-z0-9._\-/]+$/.test(path)) {
      return this.notFound(path);
    }
    try {
      const data: Uint8Array = getContext(this).resourceManager.getRawFileContentSync(RAW_PREFIX + path);
      const mime: string = mimeFor(path);
      const resp: WebResourceResponse = new WebResourceResponse();
      if (FORCE_EN && path === 'index.html') {
        // Rewrite the document at serve time: a classic script right after
        // <head> runs during parse, before the trunk-loader module script
        // (deferred) reads navigator languages — see the FORCE_EN const above.
        const text: string = util.TextDecoder.create('utf-8').decodeToString(data);
        // EC-7 instrument (kept as the durable diagnostic surface): poll
        // ui.inspect every 2s and log the open-dialog name (a modal eats all
        // input via ui.disable() — the poll line is the ground truth for
        // "dialog open vs input dead"), log every real DOM input event with
        // its hit chain, and dump dialog button rects the moment a dialog
        // opens. window.__ecSnap(tag) lets the eval channel demand an extra
        // snapshot on the spot. The one-shot battery (registry dump,
        // synthetic tap, ui.key probe) was diagnosis scaffolding and is
        // removed — it mutated app state on every fresh boot.
        const patch: string = '<script>Object.defineProperty(navigator,\'languages\',{get:function(){return [\'en\'];}});' +
          'Object.defineProperty(navigator,\'language\',{get:function(){return \'en\';}});' +
          'console.log(\'[pc] force-en navigator pinned\');</script>' +
          '<script>(function(){' +
          'var seq=0;' +
          'var evn={},evseen=0;' +
          'function onev(t){return function(e){evn[t]=(evn[t]||0)+1;evseen++;' +
          'if(evseen<=15||evn[t]%20===1){var c=(e.touches&&e.touches[0])||e;' +
          'console.log(\'[ec-insp] EV \'+t+\' #\'+evn[t]+\' at \'+(c.clientX===undefined?-1:c.clientX)+\',\'+(c.clientY===undefined?-1:c.clientY));' +
          'if(t===\'pointerdown\'){try{var hit=document.elementsFromPoint(c.clientX,c.clientY).slice(0,4).map(function(el){return el.id?el.id:el.tagName;});' +
          'console.log(\'[ec-insp] HIT \'+hit.join(\'|\')+\' RBTN button=\'+e.button+\' pointerType=\'+e.pointerType+\' isPrimary=\'+e.isPrimary);}catch(e2){}}}};}' +
          '[\'pointerdown\',\'pointermove\',\'pointerup\',\'pointercancel\',\'click\',\'touchstart\',\'touchmove\',\'touchend\',\'wheel\'].forEach(function(t){window.addEventListener(t,onev(t),true);});' +
          'window.addEventListener(\'blur\',function(){console.log(\'[ec-insp] WIN blur\');});' +
          'window.addEventListener(\'focus\',function(){console.log(\'[ec-insp] WIN focus\');});' +
          'document.addEventListener(\'visibilitychange\',function(){console.log(\'[ec-insp] vis \'+document.visibilityState);});' +
          'function compact(r){var ui=(r&&r.ui)||{};' +
          'return JSON.stringify({dialog:r.dialog,fps:r.fps,status:ui.status,playing:r.playing,t:r.time,home:ui.start_screen,kbd:r.keyboardFocus&&r.keyboardFocus.automationId,els:r.elements,winFocus:r.windowFocused});}' +
          'function snap(tag){try{' +
          'if(!window.effectcraft){console.log(\'[ec-insp] \'+tag+\': no api\');return;}' +
          'window.effectcraft.inspect().then(function(r){' +
          'console.log(\'[ec-insp] \'+tag+\' #\'+(++seq)+\' \'+compact(r));' +
          'if(r&&r.dialog){window.effectcraft.request(\'ui.elements\',{prefix:\'dialog\'}).then(function(els){' +
          'console.log(\'[ec-insp] dialog-els: \'+JSON.stringify(els).substring(0,800));' +
          '}).catch(function(e){console.log(\'[ec-insp] dialog-els ERR \'+String(e));});}' +
          '}).catch(function(e){console.log(\'[ec-insp] \'+tag+\' ERR \'+String(e));});' +
          '}catch(e){console.log(\'[ec-insp] \'+tag+\' EXC \'+String(e));}}' +
          'window.__ecSnap=snap;' +
          'console.log(\'[ec-insp] script armed\');' +
          'var waited=0;var boot=setInterval(function(){' +
          'if(window.effectcraft&&window.effectcraft.inspect){clearInterval(boot);snap(\'first\');setInterval(function(){snap(\'poll\');},2000);}' +
          'else if((waited+=500)>120000){clearInterval(boot);console.log(\'[ec-insp] boot timeout, no api\');}},500);' +
          '})();</script>';
        const at: number = text.indexOf('<head>');
        if (at < 0) {
          hilog.warn(0x0000, TAG, 'FORCE_EN: <head> not found, serving raw index.html');
          resp.setResponseData(data.buffer as ArrayBuffer);
        } else {
          resp.setResponseData(text.substring(0, at + 6) + patch + text.substring(at + 6));
          hilog.info(0x0000, TAG, 'FORCE_EN: index.html patched (navigator pinned to en)');
        }
      } else {
        resp.setResponseData(data.buffer as ArrayBuffer);
      }
      resp.setResponseMimeType(mime);
      if (mime.startsWith('text/') || mime === 'application/json' || mime === 'image/svg+xml') {
        resp.setResponseEncoding('utf-8');
      }
      resp.setResponseCode(200);
      resp.setReasonMessage('OK');
      const hdr: Header = { headerKey: 'Cache-Control', headerValue: 'no-store' };
      resp.setResponseHeader([hdr]);
      resp.setResponseIsReady(true);
      return resp;
    } catch (e) {
      hilog.warn(0x0000, TAG, 'rawfile miss: ' + path);
      return this.notFound(path);
    }
  }

  // File opens go through <input type=file>; take over with the system picker.
  private pickFiles(event: OnShowFileSelectorEvent): boolean {
    hilog.info(0x0000, TAG, 'file selector requested (multi=' +
      (event.fileSelector.getMode() === FileSelectorMode.FileOpenMultipleMode) + ')');
    const multi: boolean = event.fileSelector.getMode() === FileSelectorMode.FileOpenMultipleMode;
    const opts: picker.DocumentSelectOptions = new picker.DocumentSelectOptions();
    opts.maxSelectNumber = multi ? 10 : 1;
    const dvp: picker.DocumentViewPicker = new picker.DocumentViewPicker(getContext(this));
    dvp.select(opts).then((uris: Array<string>) => {
      event.result.handleFileList(uris);
    }).catch((err: BusinessError) => {
      hilog.warn(0x0000, TAG, 'file picker failed: ' + err.code);
      event.result.handleFileList([]);
    });
    return true;
  }

  private setupPorts(): void {
    const ports: Array<webview.WebMessagePort> = this.controller.createWebMessagePorts();
    const recv: webview.WebMessagePort = ports[1];
    recv.onMessageEvent((msg: webview.WebMessage) => {
      this.onExportMessage(msg);
    });
    this.sendPort = ports[0];
    this.recvPort = recv;
  }

  private onExportMessage(msg: webview.WebMessage): void {
    if (typeof msg !== 'string') {
      return;
    }
    let m: ExportMsg;
    try {
      m = JSON.parse(msg) as ExportMsg;
    } catch (e) {
      return;
    }
    if (m.t === 'begin') {
      this.exportChunks = [];
      this.exportName = m.name ? m.name : 'export.bin';
      hilog.info(0x0000, TAG, 'export begin: ' + this.exportName);
    } else if (m.t === 'chunk') {
      if (m.data) {
        this.exportChunks.push(m.data);
      }
    } else if (m.t === 'end') {
      hilog.info(0x0000, TAG, 'export end: chunks=' + this.exportChunks.length);
      this.saveExport();
    }
  }

  private saveExport(): void {
    const b64: string = this.exportChunks.join('');
    const name: string = this.exportName;
    this.exportChunks = [];
    this.exportName = '';
    if (b64.length === 0) {
      return;
    }
    try {
      const data: Uint8Array = new util.Base64Helper().decodeSync(b64);
      const opts: picker.DocumentSaveOptions = new picker.DocumentSaveOptions();
      opts.newFileNames = [name];
      const dvp: picker.DocumentViewPicker = new picker.DocumentViewPicker(getContext(this));
      dvp.save(opts).then((uris: Array<string>) => {
        if (uris.length === 0) {
          this.toast('保存已取消');
          return;
        }
        hilog.info(0x0000, TAG, 'export write: ' + data.byteLength + ' B -> ' + uris[0]);
        const file: fs.File = fs.openSync(uris[0], fs.OpenMode.READ_WRITE | fs.OpenMode.CREATE | fs.OpenMode.TRUNC);
        try {
          fs.writeSync(file.fd, data.buffer as ArrayBuffer);
        } finally {
          fs.closeSync(file);
        }
        this.toast('已保存 ' + name);
      }).catch((err: BusinessError) => {
        hilog.warn(0x0000, TAG, 'save failed: ' + err.code);
        this.toast('保存失败或已取消');
      });
    } catch (e) {
      hilog.warn(0x0000, TAG, 'export decode/write error');
      this.toast('保存失败');
    }
  }

  build() {
    Stack({ alignContent: Alignment.Center }) {
      Stack({ alignContent: Alignment.BottomEnd }) {
        Column() {
          Web({ src: MAIN_URL, controller: this.controller })
        .fileAccess(true)
        .domStorageAccess(true)
        .javaScriptAccess(true)
        .zoomAccess(false)
        .onLoadIntercept((event: OnLoadInterceptEvent) => {
          // F7: our virtual source passes through; external http(s) main-frame
          // navigations go to the system browser, external subresources are
          // blocked (same semantics as the old 404, but visible for links).
          const url: string = event.data.getRequestUrl();
          if (url.startsWith(URL_PREFIX)) {
            return false;
          }
          if (url.startsWith('http://') || url.startsWith('https://')) {
            if (event.data.isMainFrame()) {
              hilog.info(0x0000, TAG, 'external nav -> browser: ' + url);
              this.openExternal(url);
            } else {
              hilog.warn(0x0000, TAG, 'external subresource blocked: ' + url);
            }
            return true;
          }
          return false; // blob:/data:/about: — the webview's own business
        })
        .multiWindowAccess(true)
        .onWindowNew((event: OnWindowNewEvent) => {
          // F7 part 2: the wasm apps open their links via window.open(url,
          // '_blank') (eframe web open_url -> web_sys Window.open). With
          // multiWindowAccess(false) ArkWeb drops that popup silently — no
          // onLoadIntercept event fires, so part 1 alone cannot catch it.
          // Accept the request, route the URL to the system browser, and
          // decline the popup itself: a null controller means "no new window".
          // The setWebController call is mandatory — skipping it blocks the
          // renderer.
          hilog.info(0x0000, TAG, 'window.open -> browser: ' + event.targetUrl);
          this.openExternal(event.targetUrl);
          event.handler.setWebController(null);
        })
        .onInterceptRequest((event: OnInterceptRequestEvent) => {
          return this.handleRequest(event.request.getRequestUrl());
        })
        .onShowFileSelector((event: OnShowFileSelectorEvent) => {
          return this.pickFiles(event);
        })
        .javaScriptOnDocumentStart([
          {
            script: START_SCRIPT,
            scriptRules: [URL_PATTERN]
          }
        ])
        .onPageEnd(() => {
          // Re-hand the port to every (re)loaded page instance — a fresh port
          // pair per page, so a future reload never inherits a dead port.
          // Note: javaScriptOnDocumentStart shows no trace on this ArkWeb
          // build (hook/port console lines never surface), so the hook is
          // (re)installed from the main world here BEFORE the port is posted —
          // the message listener must exist when the port arrives, or the
          // port is lost. __pc_hook guard makes the double injection
          // idempotent.
          this.setupPorts();
          if (this.sendPort) {
            this.controller.runJavaScript(START_SCRIPT)
              .then(() => {
                this.controller.postMessage('effectcraft_port', [this.sendPort], '*');
                hilog.info(0x0000, TAG, 'port posted to page');
                this.controller.runJavaScript(
                  "console.log('[pc] main world: hook=' + (window.__pc_hook ? 'y' : 'n') + ' port=' + (window.__pc_port ? 'y' : 'n'))");
              })
              .catch((e: BusinessError) => hilog.warn(0x0000, TAG, 'hook inject failed: ' + e.code));
          }
        })
        .backgroundColor('#141414')
        .width('100%')
        .height('100%')
        }
        .width('100%')
        .height('100%')
        // EC-7 probe entry (native buttons stay alive when the web layer is
        // dead — that is the whole point): PROBE runs the fixed battery, JS
        // opens the custom-eval dialog.
        Column({ space: 8 }) {
          Button('PROBE')
            .fontSize(13)
            .fontColor(Color.White)
            .backgroundColor('#3574F0')
            .borderRadius(16)
            .padding({ left: 14, right: 14, top: 8, bottom: 8 })
            .opacity(0.85)
            .onClick(() => {
              this.runProbe();
            })
          Button('JS')
            .fontSize(13)
            .fontColor(Color.White)
            .backgroundColor('#3574F0')
            .borderRadius(16)
            .padding({ left: 14, right: 14, top: 8, bottom: 8 })
            .opacity(0.85)
            .onClick(() => {
              this.evalText = '';
              this.evalOpen = true;
            })
        }
        .margin(14)
      }
      .width('100%')
      .height('100%')
      if (this.evalOpen) {
        Column({ space: 12 }) {
          Text('页内 JS 探针（结果走 hilog: [ec-probe]）')
            .fontSize(14)
            .fontColor('#333')
          TextArea({ text: this.evalText, placeholder: "document.elementsFromPoint(innerWidth/2, innerHeight/2).map(e => e.tagName)" })
            .onChange((v: string) => {
              this.evalText = v;
            })
            .height(96)
            .fontSize(14)
          Row({ space: 12 }) {
            Button('取消')
              .onClick(() => {
                this.evalOpen = false;
              })
            Button('运行')
              .backgroundColor('#3574F0')
              .onClick(() => {
                this.evalOpen = false;
                this.evalInPage(this.evalText);
              })
          }
        }
        .padding(16)
        .borderRadius(12)
        .backgroundColor(Color.White)
        .width('72%')
      }
    }
    .width('100%')
    .height('100%')
  }
}
