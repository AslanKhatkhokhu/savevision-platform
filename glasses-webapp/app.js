/* ---------------------------------------------------------------------------
   App bootstrap + tiny screen router.

   Holds a navigation stack so 'cancel' (middle-pinch / Esc) pops back.
   Routes every normalized Input action to the active screen.
--------------------------------------------------------------------------- */

(function () {
  const root = document.getElementById('screen-root');
  const hintBar = document.getElementById('hint-bar');
  const stage = document.getElementById('stage');

  const stack = [];           // [{ name, params }]
  let active = null;          // the live screen object
  let toastTimer = null;

  const ctx = {
    get params() { return (stack[stack.length - 1] || {}).params || {}; },
    navigate(name, params = {}) { push(name, params); },
    back() { pop(); },
    setHint(html) { hintBar.innerHTML = html; },
    toast(msg) {
      let t = stage.querySelector('.toast');
      if (!t) { t = document.createElement('div'); t.className = 'toast'; stage.appendChild(t); }
      t.textContent = msg;
      t.classList.add('show');
      clearTimeout(toastTimer);
      toastTimer = setTimeout(() => t.classList.remove('show'), 1100);
    },
  };

  function mount(name, params) {
    const screen = SCREENS[name];
    if (!screen) { console.error('Unknown screen:', name); return; }
    if (active && typeof active.teardown === 'function') active.teardown();
    active = screen;
    ctx._currentParams = params;
    root.innerHTML = '';
    root.appendChild(screen.render(ctx));
  }

  function push(name, params = {}) {
    stack.push({ name, params });
    mount(name, params);
  }

  function pop() {
    if (stack.length <= 1) { ctx.toast('Home'); return; }
    stack.pop();
    const top = stack[stack.length - 1];
    mount(top.name, top.params);
  }

  // Route all input to the active screen.
  Input.onAction((action) => {
    if (active && typeof active.onAction === 'function') active.onAction(action, ctx);
  });

  Input.init();
  push('home');
})();
