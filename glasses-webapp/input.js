/* ---------------------------------------------------------------------------
   Input abstraction layer for Ray-Ban Display web apps.

   The glasses are driven by the Meta Neural Band with a FIXED gesture set:
     swipe up / down / left / right, index-pinch = ENTER, middle-pinch = CANCEL.
   Custom gestures are not available.

   Meta's rule of thumb: "if your web app works on a desktop browser with the
   arrow keys and Enter, it should also work on your glasses." So we map both
   sources into one normalized action stream:

       'up' | 'down' | 'left' | 'right' | 'enter' | 'cancel'

   Your screens only ever listen for those six actions. When the real device
   runtime exposes a Neural Band JS event, wire it in `attachDeviceGestures()`
   below — nothing else in the app needs to change.
--------------------------------------------------------------------------- */

const Input = (() => {
  const listeners = new Set();

  function emit(action) {
    for (const fn of listeners) fn(action);
  }

  /** Subscribe to normalized actions. Returns an unsubscribe fn. */
  function onAction(fn) {
    listeners.add(fn);
    return () => listeners.delete(fn);
  }

  // ---- Source 1: desktop keyboard (also the DevTools emulator) ----
  const KEY_MAP = {
    ArrowUp: 'up',
    ArrowDown: 'down',
    ArrowLeft: 'left',
    ArrowRight: 'right',
    Enter: 'enter',
    ' ': 'enter',        // space as a convenient alt-select while prototyping
    Escape: 'cancel',
    Backspace: 'cancel',
  };

  function attachKeyboard() {
    window.addEventListener('keydown', (e) => {
      const action = KEY_MAP[e.key];
      if (!action) return;
      e.preventDefault();   // stop the page from scrolling on arrows/space
      emit(action);
    });
  }

  // ---- Source 2: real Neural Band gestures (device only) ----
  // The device runtime injects gesture events. The exact event name/shape is
  // still settling in the developer preview, so we listen defensively for a
  // few likely shapes. On desktop none of these fire — keyboard covers it.
  const GESTURE_MAP = {
    swipeUp: 'up', swipeDown: 'down', swipeLeft: 'left', swipeRight: 'right',
    up: 'up', down: 'down', left: 'left', right: 'right',
    pinchIndex: 'enter', indexPinch: 'enter', select: 'enter', enter: 'enter',
    pinchMiddle: 'cancel', middlePinch: 'cancel', cancel: 'cancel', back: 'cancel',
  };

  function normalizeGesture(name) {
    if (!name) return null;
    return GESTURE_MAP[name] || GESTURE_MAP[String(name).toLowerCase()] || null;
  }

  function attachDeviceGestures() {
    // Generic CustomEvent channel: window.dispatchEvent(new CustomEvent('mwa:gesture',{detail:{name:'swipeLeft'}}))
    window.addEventListener('mwa:gesture', (e) => {
      const action = normalizeGesture(e.detail && e.detail.name);
      if (action) emit(action);
    });

    // If/when the official SDK exposes something like window.MetaWearables.onGesture,
    // bind it here. Guarded so it's a no-op when the SDK isn't present.
    const sdk = window.MetaWearables || window.metaWearables;
    if (sdk && typeof sdk.onGesture === 'function') {
      sdk.onGesture((g) => {
        const action = normalizeGesture(g && (g.type || g.name));
        if (action) emit(action);
      });
    }
  }

  // ---- Source 3 (optional): captouch on the glasses arm ----
  // Documented as available. We expose nothing special here yet; treat a tap
  // as 'enter' if the runtime surfaces it via the gesture channel above.

  function init() {
    attachKeyboard();
    attachDeviceGestures();
  }

  return { init, onAction, emit };
})();
