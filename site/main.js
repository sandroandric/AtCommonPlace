// CommonPlace — the site's motion.
//
// The sky: one WebGL canvas behind the page.  A vertical gradient whose
// colours flow (domain-warped noise, very slow), a glow where the sun is,
// a haze of a third colour, and film grain, all in one pass.  Each section
// names a time of day; as you scroll, the palette passes from one to the
// next (blended in OKLab, eased each frame), and the words take ink or
// ivory from how light the sky is behind them.
(() => {
  const still = new URLSearchParams(location.search).has("still") ||
    matchMedia("(prefers-reduced-motion: reduce)").matches;
  const root = document.documentElement.style;

  // ---------- Palettes ----------

  const skies = {
    dawn:      { top: "#B7B1D2", bottom: "#F1CDB9", glow: "#FFE4C8", haze: "#D8C4DA", sun: [0.74, 0.96], glowA: 0.5, stars: 0 },
    morning:   { top: "#F3EDE5", bottom: "#EEDDCC", glow: "#FFF1DC", haze: "#F0DCCB", sun: [0.85, 0.05], glowA: 0.45, stars: 0 },
    golden:    { top: "#F2DFC9", bottom: "#E9BFA2", glow: "#FFDDB4", haze: "#ECC9BA", sun: [0.7, 0.3], glowA: 0.45, stars: 0 },
    dusk:      { top: "#CDBCD2", bottom: "#E9BCAC", glow: "#FFD0AE", haze: "#C6B6D4", sun: [0.5, 1.02], glowA: 0.4, stars: 0 },
    night:     { top: "#2B2E50", bottom: "#4A4870", glow: "#7E82BC", haze: "#3D3B68", sun: [0.3, 1.1], glowA: 0.35, stars: 0.5 },
    deepNight: { top: "#17192C", bottom: "#262744", glow: "#555A92", haze: "#2B2A4C", sun: [0.75, 1.15], glowA: 0.3, stars: 1 },
  };

  // sRGB <-> OKLab: blends between skies stay luminous, never grey.
  const toLinear = (c) => (c <= 0.04045 ? c / 12.92 : ((c + 0.055) / 1.055) ** 2.4);
  const toGamma = (c) => (c <= 0.0031308 ? 12.92 * c : 1.055 * c ** (1 / 2.4) - 0.055);
  const hexToLab = (hex) => {
    const n = parseInt(hex.slice(1), 16);
    const [r, g, b] = [(n >> 16) & 255, (n >> 8) & 255, n & 255].map((v) => toLinear(v / 255));
    const l = Math.cbrt(0.4122214708 * r + 0.5363325363 * g + 0.0514459929 * b);
    const m = Math.cbrt(0.2119034982 * r + 0.6806995451 * g + 0.1073969566 * b);
    const s = Math.cbrt(0.0883024619 * r + 0.2817188376 * g + 0.6299787005 * b);
    return [0.2104542553 * l + 0.793617785 * m - 0.0040720468 * s,
            1.9779984951 * l - 2.428592205 * m + 0.4505937099 * s,
            0.0259040371 * l + 0.7827717662 * m - 0.808675766 * s];
  };
  const labToRgb = ([L, A, B]) => {
    const l = (L + 0.3963377774 * A + 0.2158037573 * B) ** 3;
    const m = (L - 0.1055613458 * A - 0.0638541728 * B) ** 3;
    const s = (L - 0.0894841775 * A - 1.291485548 * B) ** 3;
    return [4.0767416621 * l - 3.3077115913 * m + 0.2309699292 * s,
            -1.2684380046 * l + 2.6097574011 * m - 0.3413193965 * s,
            -0.0041960863 * l - 0.7034186147 * m + 1.707614701 * s].map((c) => Math.min(1, Math.max(0, toGamma(c))));
  };
  const css = (rgb, a = 1) => `rgba(${rgb.map((c) => Math.round(c * 255)).join(",")},${a})`;
  const keys = ["top", "bottom", "glow", "haze"];
  for (const sky of Object.values(skies)) for (const k of keys) sky[k + "Lab"] = hexToLab(sky[k]);
  const INK = hexToLab("#1A1915"), IVORY = hexToLab("#FCF6EC");

  const mix = (a, b, t) => a + (b - a) * t;
  const mixLab = (a, b, t) => a.map((v, i) => mix(v, b[i], t));
  const smooth = (t) => t * t * (3 - 2 * t);
  const sections = [...document.querySelectorAll("main > section")];

  // The sky for the middle of the screen: between the two sections around it.
  const goal = () => {
    const middle = window.innerHeight / 2;
    const points = sections.map((s) => { const b = s.getBoundingClientRect(); return { sky: skies[s.dataset.sky], y: b.top + b.height / 2 }; });
    let a = points[0], b = points[0], t = 0;
    for (let i = 0; i < points.length - 1; i++) {
      if (middle >= points[i].y && middle <= points[i + 1].y) { a = points[i]; b = points[i + 1]; t = smooth((middle - a.y) / (b.y - a.y)); break; }
      if (middle > points[i + 1].y) a = b = points[i + 1];
    }
    const out = { sun: [mix(a.sky.sun[0], b.sky.sun[0], t), mix(a.sky.sun[1], b.sky.sun[1], t)],
                  glowA: mix(a.sky.glowA, b.sky.glowA, t), stars: mix(a.sky.stars, b.sky.stars, t) };
    for (const k of keys) out[k] = mixLab(a.sky[k + "Lab"], b.sky[k + "Lab"], t);
    return out;
  };

  let now = goal();
  const ease = (k) => {
    const g = goal();
    for (const key of keys) now[key] = mixLab(now[key], g[key], k);
    now.sun = [mix(now.sun[0], g.sun[0], k), mix(now.sun[1], g.sun[1], k)];
    now.glowA = mix(now.glowA, g.glowA, k);
    now.stars = mix(now.stars, g.stars, k);
  };

  // Words: ink on a light sky, ivory on a dark one, turning smoothly.
  const nav = document.getElementById("nav");
  const paintWords = () => {
    const light = now.top[0] * 0.4 + now.bottom[0] * 0.6;
    const t = smooth(Math.min(1, Math.max(0, (light - 0.6) / 0.14)));
    const fg = labToRgb(mixLab(IVORY, INK, t));
    root.setProperty("--fg", css(fg));
    root.setProperty("--fg-2", css(fg, t > 0.5 ? 0.72 : 0.76));
    root.setProperty("--fg-3", css(fg, 0.52));
    root.setProperty("--line", css(fg, 0.16));
    root.setProperty("--top", css(labToRgb(now.top)));
    root.setProperty("--stars", now.stars.toFixed(3));
    nav.classList.toggle("on-paper", t > 0.5);
  };

  // ---------- The WebGL sky ----------

  const canvas = document.getElementById("sky");
  const gl = canvas.getContext("webgl", { antialias: false, premultipliedAlpha: false });
  let draw = () => { canvas.style.background = `linear-gradient(${css(labToRgb(now.top))}, ${css(labToRgb(now.bottom))})`; };

  if (gl) {
    const vertex = "attribute vec2 p; void main(){ gl_Position = vec4(p, 0.0, 1.0); }";
    const fragment = `
      precision highp float;
      uniform vec2 res; uniform float t;
      uniform vec3 top, bottom, glow, haze; uniform vec2 sun; uniform float glowA;
      float hash(vec2 p){ p = fract(p * vec2(123.34, 456.21)); p += dot(p, p + 45.32); return fract(p.x * p.y); }
      float noise(vec2 p){ vec2 i = floor(p), f = fract(p); vec2 u = f * f * (3.0 - 2.0 * f);
        return mix(mix(hash(i), hash(i + vec2(1, 0)), u.x), mix(hash(i + vec2(0, 1)), hash(i + vec2(1, 1)), u.x), u.y); }
      float fbm(vec2 p){ float v = 0.0, a = 0.5; for (int i = 0; i < 5; i++){ v += a * noise(p); p = p * 2.03 + 11.7; a *= 0.5; } return v; }
      void main(){
        vec2 uv = gl_FragCoord.xy / res; uv.y = 1.0 - uv.y;
        float aspect = res.x / res.y;
        vec2 p = vec2(uv.x * aspect, uv.y) * 1.35;
        vec2 q = vec2(fbm(p + t * 0.018), fbm(p + vec2(5.2, 1.3) - t * 0.014));
        vec2 r = vec2(fbm(p + 1.8 * q + vec2(1.7, 9.2) + t * 0.022), fbm(p + 1.8 * q + vec2(8.3, 2.8) - t * 0.019));
        float f = fbm(p + 1.6 * r);
        float y = clamp(uv.y + (f - 0.5) * 0.42, 0.0, 1.0);
        vec3 col = mix(top, bottom, smoothstep(0.0, 1.0, y));
        col = mix(col, haze, smoothstep(0.5, 0.92, f) * 0.42);
        vec2 d = vec2((uv.x - sun.x) * aspect, uv.y - sun.y);
        col += glow * glowA * exp(-dot(d, d) * 2.2) * (0.75 + 0.25 * f);
        col += (hash(gl_FragCoord.xy) - 0.5) * 0.05;
        gl_FragColor = vec4(col, 1.0);
      }`;
    const compile = (type, source) => { const s = gl.createShader(type); gl.shaderSource(s, source); gl.compileShader(s); return s; };
    const program = gl.createProgram();
    gl.attachShader(program, compile(gl.VERTEX_SHADER, vertex));
    gl.attachShader(program, compile(gl.FRAGMENT_SHADER, fragment));
    gl.linkProgram(program);
    if (gl.getProgramParameter(program, gl.LINK_STATUS)) {
      gl.useProgram(program);
      gl.bindBuffer(gl.ARRAY_BUFFER, gl.createBuffer());
      gl.bufferData(gl.ARRAY_BUFFER, new Float32Array([-1, -1, 1, -1, -1, 1, 1, 1]), gl.STATIC_DRAW);
      const at = gl.getAttribLocation(program, "p");
      gl.enableVertexAttribArray(at);
      gl.vertexAttribPointer(at, 2, gl.FLOAT, false, 0, 0);
      const u = Object.fromEntries(["res", "t", "top", "bottom", "glow", "haze", "sun", "glowA"].map((n) => [n, gl.getUniformLocation(program, n)]));
      // Drawn at a fraction of the screen's pixels: the sky is soft, and the grain reads as film.
      const resize = () => {
        const scale = Math.min(window.devicePixelRatio || 1, 2) * 0.6;
        canvas.width = Math.round(innerWidth * scale);
        canvas.height = Math.round(innerHeight * scale);
        gl.viewport(0, 0, canvas.width, canvas.height);
      };
      resize();
      window.addEventListener("resize", resize);
      const start = performance.now();
      draw = () => {
        gl.uniform2f(u.res, canvas.width, canvas.height);
        gl.uniform1f(u.t, still ? 12 : (performance.now() - start) / 1000);
        for (const k of keys) gl.uniform3fv(u[k], labToRgb(now[k]));
        gl.uniform2f(u.sun, now.sun[0], now.sun[1]);
        gl.uniform1f(u.glowA, now.glowA);
        gl.drawArrays(gl.TRIANGLE_STRIP, 0, 4);
      };
    }
  }

  // ---------- The opening's papers drift apart as it scrolls away ----------

  const papers = [...document.querySelectorAll("[data-depth]")];
  const drift = () => {
    const y = window.scrollY;
    if (y > innerHeight * 1.3) return;
    for (const paper of papers) paper.style.transform = `translate3d(0, ${y * parseFloat(paper.dataset.depth)}px, 0)`;
  };

  // ---------- Scenes play as they arrive ----------

  const keep = document.getElementById("keep");
  // Play (or replay from the start) the capture: keys down, corners close, the island drops.
  const play = () => {
    keep.classList.remove("play");
    void keep.offsetWidth;
    keep.classList.add("play");
  };
  const arrive = (element) => {
    element.classList.add("in");
    if (element.classList.contains("search")) typeSearch(element);
    if (element.id === "mount") play();
  };
  document.getElementById("keys").addEventListener("click", play);
  // The reader's own ⌘ keys: left and right held together play it, once per press.
  const held = new Set();
  let fired = false;
  window.addEventListener("keydown", (e) => {
    if (e.code === "MetaLeft" || e.code === "MetaRight") held.add(e.code);
    else held.clear();
    if (held.has("MetaLeft") && held.has("MetaRight") && !fired) {
      fired = true;
      const box = keep.getBoundingClientRect();
      if (box.top > innerHeight * 0.4 || box.bottom < innerHeight * 0.6) {
        if (lenis) lenis.scrollTo(keep, { offset: -(innerHeight - keep.offsetHeight) / 2, duration: 1.6 });
        else keep.scrollIntoView({ behavior: still ? "auto" : "smooth", block: "center" });
      }
      play();
    }
  });
  window.addEventListener("keyup", (e) => { held.delete(e.code); if (!held.size) fired = false; });
  window.addEventListener("blur", () => { held.clear(); fired = false; });
  const observer = new IntersectionObserver((entries) => {
    for (const entry of entries) {
      if (!entry.isIntersecting) continue;
      arrive(entry.target);
      observer.unobserve(entry.target);
    }
  }, { threshold: 0.25 });
  document.querySelectorAll(".reveal, .download").forEach((element) => (still ? arrive(element) : observer.observe(element)));

  function typeSearch(search) {
    const typed = search.querySelector(".typed");
    const text = typed.dataset.text;
    const results = [...search.querySelectorAll(".result")];
    if (still) { typed.textContent = text; results.forEach((r) => r.classList.add("shown")); search.classList.add("typed-done"); return; }
    let index = 0;
    const tick = () => {
      typed.textContent = text.slice(0, ++index);
      if (index < text.length) setTimeout(tick, 50 + Math.random() * 70);
      else {
        search.classList.add("typed-done");
        results.forEach((r, n) => setTimeout(() => r.classList.add("shown"), 520 + n * 240));
      }
    };
    setTimeout(tick, 600);
  }

  // ---------- Smooth scrolling (not on touch, not with reduced motion) ----------

  const lenis = !still && window.Lenis ? new window.Lenis({ lerp: 0.09, anchors: true }) : null;

  // ---------- The nav's mark: its sun sets as the page goes from dawn to night ----------

  const sun = document.getElementById("mark-sun");
  const paintMark = () => {
    const room = document.documentElement.scrollHeight - innerHeight;
    const p = room > 0 ? Math.min(1, Math.max(0, scrollY / room)) : 0;
    sun.setAttribute("cy", (46 + p * 38).toFixed(2));
  };

  // ---------- The collage leans with the pointer ----------

  const collage = document.querySelector(".collage");
  let lean = { x: 0, y: 0 }, leanGoal = { x: 0, y: 0 };
  if (!still) {
    window.addEventListener("pointermove", (e) => {
      if (e.pointerType !== "mouse") return;
      leanGoal = { x: (e.clientX / innerWidth - 0.5) * 2, y: (e.clientY / innerHeight - 0.5) * 2 };
    }, { passive: true });
  }
  const paintLean = () => {
    if (scrollY > innerHeight * 1.2) return;
    lean = { x: mix(lean.x, leanGoal.x, rate(0.06)), y: mix(lean.y, leanGoal.y, rate(0.06)) };
    collage.style.setProperty("--px", lean.x.toFixed(3));
    collage.style.setProperty("--py", lean.y.toFixed(3));
  };

  // ---------- Filing follows the scroll: scattered as the table comes in at the bottom, filed by the middle of the screen ----------

  const table = document.querySelector(".table");
  let filing = still ? 1 : 0;
  const paintFiling = () => {
    const box = table.getBoundingClientRect();
    const goal = still ? 1 : Math.min(1, Math.max(0, (innerHeight * 0.95 - box.top) / (innerHeight * 0.42)));
    filing = still ? 1 : mix(filing, goal, rate(0.12));
    table.style.setProperty("--p", filing.toFixed(4));
    table.classList.toggle("filed", filing > 0.97);
  };

  // ---------- The finder: corners close around anything you could keep; a click keeps it ----------

  const finder = document.getElementById("finder");
  let target = null, keptTimer = 0;
  const place = () => {
    if (!target) return;
    const r = target.getBoundingClientRect();
    finder.style.transform = `translate(${r.left}px, ${r.top}px)`;
    finder.style.width = `${r.width}px`;
    finder.style.height = `${r.height}px`;
  };
  const aim = (element) => {
    if (element === target) return;
    target = element;
    finder.classList.remove("on", "kept");
    if (!element) return;
    place();
    void finder.offsetWidth;
    finder.classList.add("on");
  };
  document.addEventListener("pointerover", (e) => aim(e.target.closest("[data-keep]")));
  document.addEventListener("pointerout", (e) => { if (target && !target.contains(e.relatedTarget)) aim(null); });
  document.addEventListener("focusin", (e) => aim(e.target.closest("[data-keep]")));
  document.addEventListener("focusout", () => aim(null));
  document.addEventListener("click", (e) => {
    const element = e.target.closest("[data-keep]");
    if (!element) return;
    aim(element);
    finder.classList.remove("kept");
    void finder.offsetWidth;
    finder.classList.add("kept");
    clearTimeout(keptTimer);
    keptTimer = setTimeout(() => finder.classList.remove("kept"), 1400);
    if (element.id === "get") {
      const label = element.textContent;
      element.textContent = "Downloading…";
      setTimeout(() => (element.textContent = label), 3500);
    }
  });

  // ---------- One page view (no cookies; only the referring site's host is kept) ----------

  try {
    const ref = document.referrer && new URL(document.referrer).host !== location.host ? document.referrer : "";
    navigator.sendBeacon?.("/api/hit", JSON.stringify({ ref }));
  } catch {}

  // ---------- One loop ----------

  // Easing per frame, scaled to the time since the last one: the same pace
  // at 30, 60 or 120 frames a second.
  let last = performance.now(), dt = 1;
  const rate = (k) => 1 - Math.pow(1 - k, dt);
  const frame = (time) => {
    dt = Math.min(6, Math.max(0.25, (time - last) / (1000 / 60)));
    last = time;
    lenis?.raf(time);
    ease(still ? 1 : rate(0.07));
    paintWords();
    draw();
    paintMark();
    paintFiling();
    place();
    if (!still) { drift(); paintLean(); }
  };
  frame(performance.now());
  if (still) {
    const once = () => frame(performance.now());
    window.addEventListener("scroll", once, { passive: true });
    window.addEventListener("resize", once);
  } else {
    const loop = (time) => { frame(time); requestAnimationFrame(loop); };
    requestAnimationFrame(loop);
  }
})();
