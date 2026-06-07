/* ---------------------------------------------------------------------------
   Screens.

   A "screen" is an object: { render(ctx), onAction(action, ctx) }.
   - render(ctx) returns an HTMLElement to mount.
   - onAction(action, ctx) handles one of: up|down|left|right|enter|cancel.

   `ctx` is provided by the router (app.js):
       ctx.navigate(name, params)   go to another screen
       ctx.back()                   pop to the previous screen
       ctx.toast(msg)               brief HUD message
       ctx.setHint(html)            set the bottom legend
       ctx.params                   params passed into this screen

   Keep each screen to ONE job and a few big targets — it's a HUD, not a page.
--------------------------------------------------------------------------- */

/* Small helper to build elements without a framework. */
function el(tag, attrs = {}, children = []) {
  const node = document.createElement(tag);
  for (const [k, v] of Object.entries(attrs)) {
    if (k === 'class') node.className = v;
    else if (k === 'html') node.innerHTML = v;
    else node.setAttribute(k, v);
  }
  for (const c of [].concat(children)) {
    node.appendChild(typeof c === 'string' ? document.createTextNode(c) : c);
  }
  return node;
}

/* A reusable focusable vertical list. Tracks its own focus index. */
function makeList(items) {
  let focus = 0;
  const root = el('div', { class: 'list' });

  function paint() {
    [...root.children].forEach((row, i) =>
      row.classList.toggle('is-focused', i === focus)
    );
  }

  items.forEach((it) => {
    root.appendChild(
      el('div', { class: 'list-item' }, [
        el('span', { class: 'icon' }, it.icon || '•'),
        el('span', {}, it.label),
      ])
    );
  });
  paint();

  return {
    root,
    move(dir) {
      if (dir === 'up') focus = (focus - 1 + items.length) % items.length;
      if (dir === 'down') focus = (focus + 1) % items.length;
      paint();
    },
    current() { return items[focus]; },
  };
}

/* ===========================  HOME  =================================== */
const HomeScreen = (() => {
  let list;
  const ITEMS = [
    { id: 'clock',   icon: '🕒', label: 'Clock' },
    { id: 'counter', icon: '🔢', label: 'Tally Counter' },
    { id: 'compass', icon: '🧭', label: 'Heading (sensors)' },
    { id: 'about',   icon: 'ℹ️', label: 'About this starter' },
  ];

  return {
    render(ctx) {
      ctx.setHint(`
        <span><span class="key">↑</span><span class="key">↓</span> move</span>
        <span><span class="key">Enter</span> select</span>`);
      list = makeList(ITEMS);
      return el('div', {}, [
        el('div', { class: 'screen-title' }, 'Ray-Ban Display'),
        el('div', { class: 'screen-subtitle' }, 'Web App starter — pick a demo'),
        list.root,
      ]);
    },
    onAction(action, ctx) {
      if (action === 'up' || action === 'down') list.move(action);
      else if (action === 'enter') ctx.navigate(list.current().id);
      else if (action === 'cancel') ctx.toast('Already home');
    },
  };
})();

/* ===========================  CLOCK  ================================== */
const ClockScreen = (() => {
  let timer, bigEl;
  function fmt() {
    const d = new Date();
    return d.toLocaleTimeString([], { hour: '2-digit', minute: '2-digit', second: '2-digit' });
  }
  return {
    render(ctx) {
      ctx.setHint(`<span><span class="key">Esc</span> back</span>`);
      bigEl = el('div', { class: 'big' }, fmt());
      timer = setInterval(() => { bigEl.textContent = fmt(); }, 1000);
      return el('div', { class: 'detail' }, [
        bigEl,
        el('div', { class: 'label' }, 'local time'),
      ]);
    },
    onAction(action, ctx) {
      if (action === 'cancel') ctx.back();
    },
    teardown() { clearInterval(timer); },
  };
})();

/* =========================  TALLY COUNTER  =========================== */
/* Shows local persistence (allowed capability) + up/down/enter use. */
const CounterScreen = (() => {
  const KEY = 'mwa.counter';
  let value = 0, bigEl;
  return {
    render(ctx) {
      ctx.setHint(`
        <span><span class="key">↑</span> +1</span>
        <span><span class="key">↓</span> -1</span>
        <span><span class="key">Enter</span> reset</span>
        <span><span class="key">Esc</span> back</span>`);
      value = parseInt(localStorage.getItem(KEY) || '0', 10);
      bigEl = el('div', { class: 'big' }, String(value));
      return el('div', { class: 'detail' }, [
        bigEl,
        el('div', { class: 'label' }, 'tally — saved on device'),
      ]);
    },
    onAction(action, ctx) {
      if (action === 'up') value++;
      else if (action === 'down') value--;
      else if (action === 'enter') { value = 0; ctx.toast('Reset'); }
      else if (action === 'cancel') return ctx.back();
      localStorage.setItem(KEY, String(value));
      bigEl.textContent = String(value);
    },
  };
})();

/* ===========================  COMPASS  =============================== */
/* Demonstrates motion/orientation sensor access (a documented capability).
   On desktop with no sensors it shows a placeholder. */
const CompassScreen = (() => {
  let bigEl, handler;
  return {
    render(ctx) {
      ctx.setHint(`<span><span class="key">Esc</span> back</span>`);
      bigEl = el('div', { class: 'big' }, '— —');
      const label = el('div', { class: 'label' }, 'compass heading (deviceorientation)');

      handler = (e) => {
        // alpha = compass heading on most devices
        const a = e.alpha;
        if (typeof a === 'number') bigEl.textContent = Math.round(a) + '°';
      };
      window.addEventListener('deviceorientation', handler);

      // No sensor on desktop → make that explicit instead of looking broken.
      setTimeout(() => {
        if (bigEl.textContent === '— —') {
          bigEl.textContent = 'n/a';
          label.textContent = 'no orientation sensor in this browser';
        }
      }, 1200);

      return el('div', { class: 'detail' }, [bigEl, label]);
    },
    onAction(action, ctx) {
      if (action === 'cancel') ctx.back();
    },
    teardown() { window.removeEventListener('deviceorientation', handler); },
  };
})();

/* ===========================  ABOUT  ================================= */
const AboutScreen = {
  render(ctx) {
    ctx.setHint(`<span><span class="key">Esc</span> back</span>`);
    return el('div', {}, [
      el('div', { class: 'screen-title' }, 'About'),
      el('div', { class: 'screen-subtitle' }, 'Starter for Meta Ray-Ban Display'),
      el('div', { class: 'list' }, [
        el('div', { class: 'list-item' }, '600×600 HUD, high-contrast'),
        el('div', { class: 'list-item' }, 'Input: arrows + Enter + Esc'),
        el('div', { class: 'list-item' }, 'Neural Band-ready event layer'),
      ]),
    ]);
  },
  onAction(action, ctx) { if (action === 'cancel') ctx.back(); },
};

/* Registry consumed by the router. */
const SCREENS = {
  home: HomeScreen,
  clock: ClockScreen,
  counter: CounterScreen,
  compass: CompassScreen,
  about: AboutScreen,
};
