/* Keynod landing page. Vanilla JS, no dependencies, no network calls. */

// ---------------------------------------------------------------------------
// The one place to change the repository address before publishing.
// Every GitHub link and the clone command on the page are filled from it.
const REPO_URL = "https://github.com/OnurrUgur/keynod";
// ---------------------------------------------------------------------------

(function () {
  "use strict";

  const root = document.documentElement;
  root.classList.remove("no-js");
  root.classList.add("js");

  const reduceMotion = window.matchMedia("(prefers-reduced-motion: reduce)");
  const $ = (sel, el = document) => el.querySelector(sel);
  const $$ = (sel, el = document) => Array.from(el.querySelectorAll(sel));

  // ---------- Repository links ----------
  $$("[data-repo]").forEach((a) => {
    a.href = REPO_URL + (a.getAttribute("data-repo-path") || "");
    a.rel = "noopener";
  });
  $$("[data-repo-text]").forEach((el) => {
    el.textContent = REPO_URL + (el.getAttribute("data-repo-text") || "");
  });

  // ---------- Reveal on scroll ----------
  const revealIO = "IntersectionObserver" in window
    ? new IntersectionObserver((entries) => {
        entries.forEach((e) => {
          if (e.isIntersecting) { e.target.classList.add("in"); revealIO.unobserve(e.target); }
        });
      }, { rootMargin: "0px 0px -8% 0px", threshold: 0.12 })
    : null;
  $$(".reveal").forEach((el) => (revealIO ? revealIO.observe(el) : el.classList.add("in")));

  const circle = $(".doodle-circle");
  if (circle && revealIO) {
    const io = new IntersectionObserver((entries) => {
      if (entries.some((e) => e.isIntersecting)) { circle.classList.add("drawn"); io.disconnect(); }
    }, { threshold: 0.6 });
    io.observe(circle);
  }

  // ---------- Loops that only run while their section is on screen ----------
  const plays = $$("[data-play]");
  if ("IntersectionObserver" in window) {
    const playIO = new IntersectionObserver((entries) => {
      entries.forEach((e) => e.target.classList.toggle("playing", e.isIntersecting));
    }, { threshold: 0.25 });
    plays.forEach((n) => playIO.observe(n));
  } else {
    plays.forEach((n) => n.classList.add("playing"));
  }

  // ---------- Count-ups (and count-downs to zero) ----------
  const counters = $$(".count[data-to]");
  function runCount(n) {
    const to = Number(n.dataset.to);
    const from = n.dataset.from != null ? Number(n.dataset.from) : 0;
    const t0 = performance.now();
    const dur = 1200;
    const tick = (t) => {
      const k = Math.min(1, (t - t0) / dur);
      const e = 1 - Math.pow(1 - k, 3);
      n.textContent = String(Math.round(from + (to - from) * e));
      if (k < 1) requestAnimationFrame(tick);
    };
    requestAnimationFrame(tick);
  }
  if ("IntersectionObserver" in window && !reduceMotion.matches) {
    counters.forEach((n) => { n.textContent = n.dataset.from != null ? n.dataset.from : "0"; });
    const countIO = new IntersectionObserver((entries) => {
      entries.forEach((e) => { if (e.isIntersecting) { countIO.unobserve(e.target); runCount(e.target); } });
    }, { threshold: 0.6 });
    counters.forEach((n) => countIO.observe(n));
  }

  // ---------- Cursor-follow light on cards (fine pointers only) ----------
  if (window.matchMedia("(hover: hover) and (pointer: fine)").matches && !reduceMotion.matches) {
    $$(".glow").forEach((card) => {
      card.addEventListener("pointermove", (e) => {
        const r = card.getBoundingClientRect();
        card.style.setProperty("--mx", (e.clientX - r.left) + "px");
        card.style.setProperty("--my", (e.clientY - r.top) + "px");
      });
    });
  }

  // ---------- Marquee: duplicate the list for a seamless loop ----------
  const track = $(".marquee-track");
  if (track && !reduceMotion.matches) {
    $$("li", track).forEach((li) => {
      const c = li.cloneNode(true);
      c.setAttribute("aria-hidden", "true");
      track.appendChild(c);
    });
  }

  // ---------- Small async helpers ----------
  const STOP = Symbol("stop");
  function newRun() { return { alive: true, speed: reduceMotion.matches ? 0 : 1, timers: [] }; }
  function stopRun(run) { if (!run) return; run.alive = false; run.timers.forEach(clearTimeout); }
  function sleep(run, ms) {
    return new Promise((resolve, reject) => {
      if (!run.alive) return reject(STOP);
      if (run.speed === 0) return resolve();
      const id = setTimeout(() => (run.alive ? resolve() : reject(STOP)), ms * run.speed);
      run.timers.push(id);
    });
  }
  function el(tag, cls, html) {
    const n = document.createElement(tag);
    if (cls) n.className = cls;
    if (html != null) n.innerHTML = html;
    return n;
  }
  function esc(s) {
    return s.replace(/[&<>"]/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;" }[c]));
  }
  // Wrap "<concealed>" in the highlight after escaping.
  function fmt(s) {
    return esc(s).replace(/&lt;concealed&gt;/g, '<span class="concealed pop">&lt;concealed&gt;</span>');
  }
  async function typeInto(run, node, text, msPerChar, after) {
    const t = document.createTextNode("");
    const caret = el("span", "caret");
    node.appendChild(t);
    node.appendChild(caret);
    if (run.speed === 0) { t.data = text; caret.remove(); return; }
    for (let i = 0; i < text.length; i++) {
      t.data += text[i];
      if (after) after();
      await sleep(run, msPerChar + (text[i] === " " ? msPerChar * 0.6 : 0));
      if (run.speed === 0) { t.data = text; break; }
    }
    caret.remove();
  }
  function restartClass(node, cls) {
    node.classList.remove(cls);
    void node.getBoundingClientRect();
    node.classList.add(cls);
  }

  // ---------- Hero scene ----------
  const stage = $("#hero-stage");
  if (stage) {
    const lines = $("#hero-lines", stage);
    const touch = $("#hero-touchid", stage);
    const card = $("#hero-phonecard", stage);
    const phoneShown = () => getComputedStyle($(".phone", stage)).display !== "none";
    const COMMAND = 'keynod run --env OPENAI_API_KEY="OpenAI/Key" -- python deploy.py';
    let visible = true;
    let wake = null;
    let heroRun = null;

    const add = (cls, html) => { const n = el("div", cls, html); lines.appendChild(n); return n; };

    async function scene(run, remote) {
      stage.classList.remove("happy", "remote", "look-up", "look-right", "nod");
      touch.className = "touchid";
      card.className = "ph-card";
      lines.innerHTML = "";
      if (remote) stage.classList.add("remote");
      await sleep(run, 500);

      const u = add("ln user", '<span class="gt">&gt;</span> ');
      stage.classList.add("look-right");
      await typeInto(run, u, "Deploy the API. The OpenAI key is in Keynod.", 36);
      await sleep(run, 650);
      add("ln", '<span class="bul">⏺</span> I\'ll pass the key through Keynod, so I never read it.');
      await sleep(run, 700);
      const b = add("ln", '<span class="bul tool">⏺</span> <b>Bash</b>(');
      await typeInto(run, b, COMMAND, 20);
      b.appendChild(document.createTextNode(")"));
      await sleep(run, 350);
      const status = add("ln out", '<span class="dim">⎿</span>  <span class="spin">✻</span> <span class="dim">Running…</span>');
      stage.classList.remove("look-right");
      stage.classList.add("look-up");
      await sleep(run, 300);

      const dlg = remote ? card : touch;
      dlg.classList.add("show");
      await sleep(run, 1100);
      dlg.classList.add("scan");
      await sleep(run, 1500);
      dlg.classList.remove("scan");
      dlg.classList.add("ok");
      await sleep(run, 250);
      stage.classList.remove("look-up");
      stage.classList.add("happy");
      if (run.speed !== 0) restartClass(stage, "nod");
      await sleep(run, 900);
      dlg.classList.remove("show");
      await sleep(run, 250);

      status.innerHTML = '<span class="dim">⎿</span>  Using OPENAI_API_KEY=<span class="concealed pop">&lt;concealed&gt;</span>';
      await sleep(run, 600);
      add("ln out", '<span class="dim">&nbsp;</span>  Deployed build 41 to production <span class="ok">✓</span>');
      await sleep(run, 800);
      add("ln", '<span class="bul">⏺</span> Done. The key stayed out of this chat.');
      await sleep(run, 4200);
    }

    async function loop() {
      let n = 0;
      heroRun = newRun();
      try {
        if (heroRun.speed === 0) { await scene(heroRun, false); return; }
        for (;;) {
          if (!visible) await new Promise((r) => (wake = r));
          const remote = n % 2 === 1 && phoneShown();
          await scene(heroRun, remote);
          n++;
        }
      } catch (e) { if (e !== STOP) throw e; }
    }

    if ("IntersectionObserver" in window) {
      new IntersectionObserver((entries) => {
        visible = entries[0].isIntersecting;
        if (visible && wake) { wake(); wake = null; }
      }).observe(stage);
    }
    loop();
    reduceMotion.addEventListener && reduceMotion.addEventListener("change", () => { stopRun(heroRun); loop(); });
  }

  // ---------- Demo terminal ----------
  const SCENARIOS = {
    run: [
      ["cmd", 'keynod run --env OPENAI_API_KEY="OpenAI/Key" -- python deploy.py | tee deploy.log'],
      ["touch", "Keynod is trying to allow “keynod run -- /opt/homebrew/bin/python3.12 deploy.py” from zsh in ~/acme-api to read: OpenAI/Key"],
      ["out", "Using OPENAI_API_KEY=<concealed>"],
      ["out", "Deployed build 41 to production ✓"],
      ["note", "# Output went to a pipe, so the value was replaced."],
    ],
    inject: [
      ["cmd", 'keynod inject "Stripe/Live Key" --to .env.local'],
      ["touch", "Keynod is trying to allow “keynod inject --to ~/shop/.env.local” from zsh in ~/shop to read: Stripe/Live Key"],
      ["out", "/Users/you/shop/.env.local"],
      ["cmd", "ls -l .env.local"],
      ["out", "-rw-------  1 you  staff  108 Nov 22 10:41 .env.local"],
      ["note", "# 0600: only you can read it."],
    ],
    phone: [
      ["note", "# Remote Mode is on. You are away from the Mac."],
      ["user", "Publish the package once the tests pass."],
      ["tool", "Bash(npm publish --access public)"],
      ["phone", { title: "Allow Claude: Bash", body: "npm publish --access public" }],
      ["out", "  ⎿  + acme-sdk@2.4.1"],
    ],
    catch: [
      ["note", "# You copy a new key from the OpenAI dashboard."],
      ["catch", "OpenAI API Key"],
      ["cmd", "keynod list openai"],
      ["out", "OpenAI API Key  [8C1D5E2B-0F3A-4B6C-9D7E-1A2B3C4D5E6F]"],
      ["out", "  Key: (concealed)"],
    ],
  };
  const ORDER = ["run", "inject", "phone", "catch"];

  const FINGERPRINT = $(".ti-print") ? $(".ti-print").innerHTML : "";
  const ICON = "assets/svg/keynod-icon.svg";

  const term = $("#term");
  if (term) {
    const out = $("#term-out");
    const body = $("#term-panel");
    const tabs = $$(".term-tab", term);
    let current = "run";
    let run = null;
    let auto = !reduceMotion.matches;
    let started = false;
    let advanceTimer = null;

    const scroll = () => { body.scrollTop = body.scrollHeight; };
    const push = (node) => { out.appendChild(node); scroll(); return node; };
    const prompt = (dir) => `<span class="pr">${dir} ❯</span> `;
    const dirFor = { run: "~/acme-api", inject: "~/shop", phone: "~/acme-sdk", catch: "~/acme-api" };

    async function play(name) {
      stopRun(run);
      clearTimeout(advanceTimer);
      run = newRun();
      const r = run;
      out.innerHTML = "";
      body.scrollTop = 0;
      const steps = SCENARIOS[name];
      try {
        await sleep(r, 350);
        for (const [kind, arg] of steps) {
          if (kind === "cmd") {
            const ln = push(el("div", "ln", prompt(dirFor[name])));
            await sleep(r, 250);
            await typeInto(r, ln, arg, 24, scroll);
            await sleep(r, 380);
          } else if (kind === "out" || kind === "warn" || kind === "note") {
            push(el("div", "ln out" + (kind === "warn" ? " warn" : kind === "note" ? " note" : ""), fmt(arg)));
            await sleep(r, kind === "note" ? 650 : 160);
          } else if (kind === "user") {
            const ln = push(el("div", "ln user", '<span class="gt">&gt;</span> '));
            await typeInto(r, ln, arg, 30, scroll);
            await sleep(r, 600);
          } else if (kind === "cc") {
            push(el("div", "ln", '<span class="bul">⏺</span>' + esc(arg.slice(1))));
            await sleep(r, 700);
          } else if (kind === "tool") {
            const m = arg.match(/^(\w+)\((.*)\)$/);
            push(el("div", "ln", `<span class="bul tool">⏺</span> <b>${esc(m[1])}</b>(${esc(m[2])})`));
            await sleep(r, 500);
          } else if (kind === "touch") {
            const w = push(el("div", "w w-touch",
              `<img src="${ICON}" alt="" width="40" height="40"><p><b>Keynod · Touch ID</b>${esc(arg)}</p><div class="ti-print">${FINGERPRINT}</div>`));
            await sleep(r, 60); w.classList.add("show");
            await sleep(r, 900); w.classList.add("scan");
            await sleep(r, 1300); w.classList.remove("scan"); w.classList.add("ok");
            await sleep(r, 600);
          } else if (kind === "phone") {
            const w = push(el("div", "w w-phone",
              `<div class="ph-app"><img src="${ICON}" alt="" width="18" height="18"> Keynod <span class="dim">iPhone · now</span></div>
               <p class="ph-q"><b>${esc(arg.title)}</b><br><code>${esc(arg.body)}</code></p>
               <div class="ph-btns"><span class="deny">Deny</span><span class="allow">Allow with Face ID</span></div>`));
            await sleep(r, 60); w.classList.add("show");
            await sleep(r, 1500); w.classList.add("ok");
            w.querySelector(".allow").textContent = "Allowed with Face ID ✓";
            await sleep(r, 700);
          } else if (kind === "reply") {
            const w = push(el("div", "w w-phone",
              `<div class="ph-app"><img src="${ICON}" alt="" width="18" height="18"> Keynod <span class="dim">iPhone · now</span></div>
               <p class="ph-q"><b>Claude is waiting for you</b><br>${esc(arg.body)}</p>
               <div class="ph-reply"></div>`));
            await sleep(r, 60); w.classList.add("show");
            await sleep(r, 700);
            await typeInto(r, w.querySelector(".ph-reply"), arg.reply, 45, scroll);
            await sleep(r, 300); w.classList.add("ok");
            await sleep(r, 600);
          } else if (kind === "catch") {
            const w = push(el("div", "w w-card",
              `<div class="kc-top"><svg class="kc-key" viewBox="0 0 24 24" width="16" height="16" aria-hidden="true"><path fill="currentColor" d="M14.5 2a7.5 7.5 0 0 0-7.1 9.9L2 17.3V22h4.7v-2.3H9v-2.3h2.3l1.1-1.1A7.5 7.5 0 1 0 14.5 2zm2 6.8a1.8 1.8 0 1 1 0-3.6 1.8 1.8 0 0 1 0 3.6z"/></svg>
               <div><b>${esc(arg)} copied</b><p class="kc-sub">Save it to Keynod Vault or clear your clipboard.</p></div></div>
               <div class="kc-btns"><span class="p">Save to Vault</span><span>Clear Clipboard</span><span>Ignore</span></div>`));
            await sleep(r, 60); w.classList.add("show");
            await sleep(r, 1600); w.classList.add("press");
            await sleep(r, 250); w.classList.remove("press"); w.classList.add("saved");
            w.querySelector(".kc-sub").textContent = "Saved to Vault ✓";
            await sleep(r, 700);
          }
          scroll();
        }
        push(el("div", "ln", prompt(dirFor[name]) + '<span class="caret"></span>'));
        if (auto && r.speed !== 0) {
          advanceTimer = setTimeout(() => {
            if (!r.alive) return;
            const next = ORDER[(ORDER.indexOf(current) + 1) % ORDER.length];
            select(next, false);
          }, 5000);
        }
      } catch (e) { if (e !== STOP) throw e; }
    }

    function select(name, byUser) {
      if (byUser) auto = false;
      current = name;
      tabs.forEach((t) => {
        const on = t.dataset.scenario === name;
        t.setAttribute("aria-selected", on ? "true" : "false");
        t.tabIndex = on ? 0 : -1;
        if (on) {
          body.setAttribute("aria-labelledby", t.id);
          // Keep the chosen tab visible in its own strip without moving the page.
          const strip = t.parentElement;
          if (strip && strip.scrollWidth > strip.clientWidth) {
            strip.scrollLeft = t.offsetLeft - (strip.clientWidth - t.offsetWidth) / 2;
          }
        }
      });
      play(name);
    }

    tabs.forEach((t, i) => {
      t.addEventListener("click", () => select(t.dataset.scenario, true));
      t.addEventListener("keydown", (e) => {
        let j = null;
        if (e.key === "ArrowRight") j = (i + 1) % tabs.length;
        else if (e.key === "ArrowLeft") j = (i - 1 + tabs.length) % tabs.length;
        else if (e.key === "Home") j = 0;
        else if (e.key === "End") j = tabs.length - 1;
        if (j !== null) { e.preventDefault(); tabs[j].focus(); select(tabs[j].dataset.scenario, true); }
      });
    });
    $("#term-skip").addEventListener("click", () => { auto = false; if (run && run.alive) run.speed = 0; });
    $("#term-replay").addEventListener("click", () => play(current));

    if ("IntersectionObserver" in window) {
      const io = new IntersectionObserver((entries) => {
        if (!started && entries[0].isIntersecting) { started = true; io.disconnect(); play(current); }
      }, { threshold: 0.35 });
      io.observe(term);
    } else {
      play(current);
    }
  }

  // ---------- Generic tabs (install box) ----------
  $$(".install-tabs").forEach((list) => {
    const tabs = $$('[role="tab"]', list);
    const show = (tab) => {
      tabs.forEach((t) => {
        const on = t === tab;
        t.setAttribute("aria-selected", on ? "true" : "false");
        t.tabIndex = on ? 0 : -1;
        document.getElementById(t.getAttribute("aria-controls")).hidden = !on;
      });
    };
    tabs.forEach((t, i) => {
      t.addEventListener("click", () => show(t));
      t.addEventListener("keydown", (e) => {
        let j = null;
        if (e.key === "ArrowRight") j = (i + 1) % tabs.length;
        else if (e.key === "ArrowLeft") j = (i - 1 + tabs.length) % tabs.length;
        if (j !== null) { e.preventDefault(); tabs[j].focus(); show(tabs[j]); }
      });
    });
  });

  // ---------- Copy buttons ----------
  function copyText(text) {
    if (navigator.clipboard && window.isSecureContext) return navigator.clipboard.writeText(text);
    return new Promise((resolve, reject) => {
      const ta = el("textarea");
      ta.value = text;
      ta.setAttribute("readonly", "");
      ta.className = "sr-only";
      document.body.appendChild(ta);
      ta.select();
      try { document.execCommand("copy") ? resolve() : reject(); } catch (e) { reject(e); }
      ta.remove();
    });
  }
  $$("[data-copy-from]").forEach((btn) => {
    btn.addEventListener("click", () => {
      const id = btn.getAttribute("data-copy-from");
      let src = document.getElementById(id);
      if (id === "install") src = $$(".ipanel", src).find((p) => !p.hidden);
      const text = src.innerText.trim() + "\n";
      copyText(text).then(() => {
        btn.textContent = "Copied ✓";
        btn.classList.add("done");
        setTimeout(() => { btn.textContent = "Copy"; btn.classList.remove("done"); }, 1800);
      }, () => { btn.textContent = "Press ⌘C"; });
    });
  });
})();
