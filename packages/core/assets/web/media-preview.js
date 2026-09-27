(function (root) {
  'use strict';
  var owner = null;
  function clock(value) {
    value = Math.max(0, Math.floor(Number(value) || 0));
    return Math.floor(value / 60) + ':' + String(value % 60).padStart(2, '0');
  }
  function mount(options) {
    if (owner) owner.close();
    var media = options.media, doc = media.ownerDocument || root.document, labels = options.labels || {};
    var box = doc.createElement('div'), tools = doc.createElement('div'), button = doc.createElement('button');
    var position = doc.createElement('input'), time = doc.createElement('span'), note = doc.createElement('span');
    box.className = 'media-preview-player'; tools.className = 'media-preview-tools'; button.className = 'media-preview-resume';
    button.type = 'button'; position.type = 'range'; position.min = '0'; position.max = '0'; position.step = '0.1';
    position.className = 'media-preview-position'; position.setAttribute('aria-label', labels.mediaPosition || 'Playback position');
    time.className = 'media-preview-time'; note.className = 'media-preview-note'; note.setAttribute('role', 'status');
    tools.appendChild(button); tools.appendChild(position); tools.appendChild(time); tools.appendChild(note);
    box.appendChild(media); box.appendChild(tools); options.container.appendChild(box); tools.hidden = true;
    var closed = false, detached = false, generation = 0, pauseTimer = null, initialTimer = null, restoring = false, played = false, pausedPosition = false;
    var saved = {time: 0, duration: 0, volume: media.volume, muted: media.muted, rate: media.playbackRate};
    var listeners = [], poster = null;
    function live() { return !closed && owner === api; }
    function on(name, fn) { media.addEventListener(name, fn); listeners.push([name, fn]); }
    function retire(replace) {
      var old = media;
      listeners.forEach(function (entry) { old.removeEventListener(entry[0], entry[1]); });
      old.onloadedmetadata = old.onerror = null;
      old.pause(); old.removeAttribute('src'); old.removeAttribute('poster'); old.load();
      if (replace) {
        media = doc.createElement(old.tagName.toLowerCase());
        media.controls = false; media.preload = 'none'; media.setAttribute('playsinline', '');
        media.volume = saved.volume; media.muted = saved.muted; media.playbackRate = saved.rate;
        if (poster) media.poster = poster;
        old.replaceWith(media); options.media = media;
        listeners.forEach(function (entry) { media.addEventListener(entry[0], entry[1]); });
        if (options.onElement) options.onElement(media);
      } else old.remove();
      // Reusing the old element can retain WebKit's native resource loader even
      // after load()/src removal. Retire it; resume owns a fresh media element.
    }
    function cancelTimers() { clearTimeout(pauseTimer); clearTimeout(initialTimer); pauseTimer = initialTimer = null; }
    function display() {
      button.textContent = saved.time > 0 ? labels.mediaResume || 'Resume playback' : labels.mediaPlay || 'Play';
      position.max = String(saved.duration || 0); position.value = String(saved.time);
      position.disabled = !saved.duration; time.textContent = clock(saved.time) + ' / ' + clock(saved.duration);
      position.setAttribute('aria-valuetext', time.textContent);
      note.textContent = played ? labels.mediaPaused || 'Paused · buffer released' : '';
    }
    function remember() {
      if (Number.isFinite(media.duration) && media.duration > 0) saved.duration = media.duration;
      if (!restoring && !pausedPosition && Number.isFinite(media.currentTime)) saved.time = media.currentTime;
      saved.volume = media.volume; saved.muted = media.muted; saved.rate = media.playbackRate;
    }
    function frame() {
      if (!media.videoWidth || !media.videoHeight) return;
      box.style.setProperty('--media-ratio', media.videoWidth + ' / ' + media.videoHeight);
      if (media.readyState < 2) return;
      var canvas = doc.createElement('canvas'), scale = Math.min(1, 640 / media.videoWidth, 360 / media.videoHeight);
      canvas.width = Math.max(1, Math.round(media.videoWidth * scale)); canvas.height = Math.max(1, Math.round(media.videoHeight * scale));
      try {
        canvas.getContext('2d').drawImage(media, 0, 0, canvas.width, canvas.height);
        poster = canvas.toDataURL('image/jpeg', 0.8); media.poster = poster;
      } catch (_) { /* A poster failure must not prevent releasing the media source. */ }
      canvas.width = canvas.height = 0;
    }
    function nativePresentation() { return doc.fullscreenElement === media || doc.pictureInPictureElement === media || media.webkitDisplayingFullscreen; }
    function suspend(ended) {
      if (!live() || detached) return;
      // Native fullscreen/PiP controls cannot reach our sibling resume button.
      // Keep that useful player intact until returning to the inline surface.
      if (nativePresentation()) return;
      cancelTimers(); remember(); frame(); if (ended) saved.time = 0;
      detached = true; restoring = false; generation++;
      retire(true);
      box.dataset.state = 'paused'; tools.hidden = false; display();
    }
    function pauseLater() {
      if (!live() || detached || restoring) return;
      clearTimeout(pauseTimer);
      pauseTimer = setTimeout(function () {
        if (!live() || detached || !media.paused || restoring) return;
        if (media.seeking) { pauseLater(); return; }
        suspend(media.ended);
      }, 120);
    }
    function resume() {
      if (!live()) return Promise.resolve();
      cancelTimers();
      if (!detached) return Promise.resolve(media.play()).catch(function () { pauseLater(); });
      var attempt = ++generation;
      detached = false; restoring = true; pausedPosition = false; tools.hidden = true; box.dataset.state = 'loading'; media.controls = true;
      media.volume = saved.volume; media.muted = saved.muted; media.playbackRate = saved.rate;
      media.preload = 'metadata'; media.src = options.url;
      // Call play while the user's click still grants playback activation, not
      // after awaiting metadata (notably important on mobile browsers).
      var playing;
      try { playing = media.play(); } catch (issue) { playing = Promise.reject(issue); }
      return Promise.resolve(playing).catch(function () {
        if (!live() || generation !== attempt) return;
        // Autoplay/activation denial leaves a deliberate retry button and does
        // not keep a failed play attempt downloading in the background.
        suspend(false);
      });
    }
    function close() {
      if (closed) return;
      closed = true; generation++; cancelTimers();
      retire(false); listeners = [];
      if (doc.removeEventListener) doc.removeEventListener('fullscreenchange', presentationChanged);
      button.onclick = position.oninput = null;

      poster = null; box.remove(); if (owner === api) owner = null;
    }
    var api = {close: close, resume: resume, suspend: function () { suspend(false); },
      element: function () { return media; },
      snapshot: function () { return {closed: closed, detached: detached, time: saved.time, duration: saved.duration, poster: !!poster}; }};
    owner = api;
    button.onclick = function () { resume(); };
    position.oninput = function () {
      saved.time = Math.max(0, Math.min(saved.duration, Number(position.value) || 0)); display();
    };
    on('error', function () {
      if (!live() || detached) return;
      var issue = new Error('media-failed'); issue.code = 'failed';
      close(); if (options.onError) options.onError(issue);
    });
    on('loadedmetadata', function () {
      if (!live() || detached) return;
      if (options.onReady) options.onReady();
      if (Number.isFinite(media.duration)) saved.duration = media.duration;
      if (restoring) {
        // load() may reset playbackRate to defaultPlaybackRate after src is set.
        media.volume = saved.volume; media.muted = saved.muted; media.playbackRate = saved.rate;
        var target = Math.min(saved.time, Math.max(0, saved.duration - 0.01));
        if (target > 0) { try { media.currentTime = target; } catch (_) {} }
        restoring = false;
      } else if (!played && media.paused) {
        // preload is a browser hint, not a byte cap. Once metadata is known,
        // explicitly end speculative reads; a ready first frame is bounded.
        initialTimer = setTimeout(function () { if (live() && !played && media.paused) suspend(false); }, 120);
      }
    });
    on('play', function () { if (!live() || detached) return; played = true; pausedPosition = false; cancelTimers(); tools.hidden = true; box.dataset.state = 'playing'; });
    on('playing', function () { if (live() && !detached) { media.removeAttribute('poster'); poster = null; } });
    function presentationChanged() { if (live() && media.paused && !nativePresentation()) pauseLater(); }
    if (doc.addEventListener) doc.addEventListener('fullscreenchange', presentationChanged);
    on('leavepictureinpicture', presentationChanged);
    on('webkitendfullscreen', presentationChanged);
    on('pause', function () {
      // WebKit's paused AV clock can reset after a playback-rate change. Read
      // the actual pause position now, not after the resource-release delay.
      if (live() && !detached && !restoring && !media.seeking) { remember(); pausedPosition = true; }
      pauseLater();
    });
    on('seeked', function () {
      if (live() && !detached && media.paused && played) {
        pausedPosition = false; remember(); pausedPosition = true; pauseLater();
      }
    });
    on('ended', function () { suspend(true); });
    media.controls = true; media.preload = 'metadata'; media.setAttribute('playsinline', ''); media.src = options.url;
    return api;
  }
  var api = {mount: mount, clock: clock};
  if (typeof module === 'object') module.exports = api;
  root.LegnaMediaPreview = api;
})(typeof window === 'object' ? window : globalThis);
