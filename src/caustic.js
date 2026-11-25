import { FRAG } from "./shader.js";

export const ICONS = ["ring", "grid", "gem", "twist", "slab", "arch", "tile", "stack", "fan"];
export const STATES = ["idle", "thinking", "speaking", "done"];

const SPEED = [1.0, 2.6, 1.6, 0.6];
const SPRING = {
  follow: { k: 320, c: 32 },
  settle: { k: 220, c: 29.7 },
  lift: { k: 400, c: 40 },
  pressIn: { k: 900, c: 60 },
  pressOut: { k: 600, c: 34.3 },
  sig: { k: 260, c: 32.2 },
  lit: { k: 170, c: 26.1 },
};
const POSE = { yaw: 0.314, pitch: 0.209, liftPx: 1.5, litYaw: -0.12, litPitch: 0.05, sweep: 0.6 };
const KEYS = ["yaw", "pitch", "lift", "press", "sig", "lit"];
const VERT = "#version 300 es\nlayout(location=0) in vec2 a; void main(){ gl_Position = vec4(a, 0.0, 1.0); }";
const UNIFORMS = ["uOrigin", "uRes", "uSize", "uTime", "uPhase", "uState", "uDoneT", "uVoice", "uIcon", "uSeed", "uSS", "uPose", "uFx"];

const seedOf = (i) => (i * 0.618034 + 0.137) % 1;
const stillTime = (i) => 2.2 + seedOf(i) * 7.0;
const ssFor = (css) => (css <= 40 ? 3 : css <= 80 ? 2 : 1);
const easeOut = (t) => 1 - Math.pow(1 - t, 3);
const reducedQuery = typeof matchMedia === "function" ? matchMedia("(prefers-reduced-motion: reduce)") : { matches: false, addEventListener() {} };

function voiceAt(t) {
  const gate = Math.min(1, Math.max(0, (2.1 - (t % 2.7)) * 6)) * Math.min(1, (t % 2.7) * 8);
  const syl = Math.pow(Math.max(0, Math.sin(t * 11.5 + Math.sin(t * 2.3) * 1.9)), 1.4);
  return gate * syl * (0.62 + 0.38 * Math.sin(t * 1.7 + 1.0) * Math.sin(t * 0.83 + 0.4));
}

const atRest = (p) => Math.abs(p.x - p.to) < 1e-4 && Math.abs(p.v) < 1e-3;
function integrate(p, dt) {
  const n = Math.max(1, Math.ceil(dt * 240)), h = dt / n, { k, c } = p.cfg;
  for (let i = 0; i < n; i++) { p.v += (-k * (p.x - p.to) - c * p.v) * h; p.x += p.v * h; }
  if (atRest(p)) { p.x = p.to; p.v = 0; }
}

let gl = null, canvas = null, prog = null, loc = null, fbo = null, tex = null, texSize = 0;
let raf = 0, last = 0, clock = 0, io = null;
const icons = new Set();
const visible = new Set();

function compile() {
  const vbo = gl.createBuffer();
  gl.bindBuffer(gl.ARRAY_BUFFER, vbo);
  gl.bufferData(gl.ARRAY_BUFFER, new Float32Array([-1, -1, 3, -1, -1, 3]), gl.STATIC_DRAW);
  gl.bindVertexArray(gl.createVertexArray());
  gl.enableVertexAttribArray(0);
  gl.vertexAttribPointer(0, 2, gl.FLOAT, false, 0, 0);
  const shader = (type, src) => {
    const s = gl.createShader(type);
    gl.shaderSource(s, src);
    gl.compileShader(s);
    if (!gl.getShaderParameter(s, gl.COMPILE_STATUS)) throw new Error(gl.getShaderInfoLog(s));
    return s;
  };
  prog = gl.createProgram();
  gl.attachShader(prog, shader(gl.VERTEX_SHADER, VERT));
  gl.attachShader(prog, shader(gl.FRAGMENT_SHADER, FRAG));
  gl.linkProgram(prog);
  if (!gl.getProgramParameter(prog, gl.LINK_STATUS)) throw new Error(gl.getProgramInfoLog(prog));
  gl.useProgram(prog);
  loc = Object.fromEntries(UNIFORMS.map((u) => [u, gl.getUniformLocation(prog, u)]));
  gl.enable(gl.SCISSOR_TEST);
  fbo = null; tex = null; texSize = 0;
}

function context() {
  if (gl) return gl;
  canvas = document.createElement("canvas");
  canvas.setAttribute("aria-hidden", "true");
  canvas.style.cssText = "position:fixed;left:0;top:0;pointer-events:none;z-index:2147483647";
  gl = canvas.getContext("webgl2", { alpha: true, premultipliedAlpha: true, antialias: false, depth: false, stencil: false, powerPreference: "low-power" });
  if (!gl) return null;
  compile();
  canvas.addEventListener("webglcontextlost", (e) => { e.preventDefault(); stop(); prog = null; });
  canvas.addEventListener("webglcontextrestored", () => { compile(); icons.forEach((s) => (s.stillKey = "")); kick(); });
  io = new IntersectionObserver((entries) => {
    for (const en of entries) { const s = en.target._caustic; if (s) en.isIntersecting ? visible.add(s) : visible.delete(s); }
    kick();
  }, { rootMargin: "96px" });
  document.addEventListener("visibilitychange", () => (document.hidden ? stop() : kick()));
  addEventListener("resize", kick, { passive: true });
  addEventListener("scroll", kick, { passive: true });
  reducedQuery.addEventListener("change", () => { icons.forEach((s) => { s.stillKey = ""; retarget(s); }); kick(); });
  document.body.appendChild(canvas);
  return gl;
}

function draw(icon, x, y, px, css, o) {
  gl.viewport(x, y, px, px);
  gl.scissor(Math.max(0, x), Math.max(0, y), px, px);
  gl.uniform2f(loc.uOrigin, x, y);
  gl.uniform2f(loc.uRes, px, px);
  gl.uniform1f(loc.uSize, css);
  gl.uniform1f(loc.uTime, o.time);
  gl.uniform1f(loc.uPhase, o.phase);
  gl.uniform4f(loc.uState, ...o.weights);
  gl.uniform1f(loc.uDoneT, o.doneT);
  gl.uniform1f(loc.uVoice, o.voice);
  gl.uniform1f(loc.uIcon, icon);
  gl.uniform1f(loc.uSeed, seedOf(icon));
  gl.uniform1i(loc.uSS, o.ss ?? ssFor(css));
  gl.uniform4f(loc.uPose, ...o.pose);
  gl.uniform4f(loc.uFx, ...o.fx);
  gl.drawArrays(gl.TRIANGLES, 0, 3);
}

function stillParams(icon, state) {
  const i = Math.max(0, STATES.indexOf(state));
  return { time: stillTime(icon), phase: 0, weights: STATES.map((_, j) => (j === i ? 1 : 0)), doneT: state === "done" ? 1.6 : 99, voice: state === "speaking" ? 0.7 : 0 };
}

/**
 * Render one icon into a 2D canvas with straight alpha. Every field but name is optional.
 * time, phase, weights, doneT and voice drive the animation; pose is [yaw, pitch, lift, press]; fx is [signature, lit, sweep, 0].
 */
export function render({ name, size = 96, scale = globalThis.devicePixelRatio || 1, state = "idle", ss, pose = [0, 0, 0, 0], fx = [0, 0, -1, 0], target, ...frame } = {}) {
  const icon = ICONS.indexOf(name);
  if (icon < 0) throw new Error("caustic: unknown icon " + name);
  if (!context() || !prog) return null;
  const px = Math.max(1, Math.round(size * scale));
  if (px > texSize) {
    if (tex) gl.deleteTexture(tex);
    if (!fbo) fbo = gl.createFramebuffer();
    tex = gl.createTexture();
    gl.bindTexture(gl.TEXTURE_2D, tex);
    gl.texStorage2D(gl.TEXTURE_2D, 1, gl.RGBA8, px, px);
    gl.bindFramebuffer(gl.FRAMEBUFFER, fbo);
    gl.framebufferTexture2D(gl.FRAMEBUFFER, gl.COLOR_ATTACHMENT0, gl.TEXTURE_2D, tex, 0);
    texSize = px;
  }
  gl.bindFramebuffer(gl.FRAMEBUFFER, fbo);
  gl.viewport(0, 0, px, px);
  gl.scissor(0, 0, px, px);
  gl.clearColor(0, 0, 0, 0);
  gl.clear(gl.COLOR_BUFFER_BIT);
  draw(icon, 0, 0, px, size, { ...stillParams(icon, state), ...frame, ss, pose, fx });
  const buf = new Uint8Array(px * px * 4);
  gl.readPixels(0, 0, px, px, gl.RGBA, gl.UNSIGNED_BYTE, buf);
  gl.bindFramebuffer(gl.FRAMEBUFFER, null);
  const out = target || document.createElement("canvas");
  out.width = px; out.height = px;
  const c2 = out.getContext("2d"), img = c2.createImageData(px, px);
  for (let y = 0; y < px; y++) {
    for (let x = 0; x < px; x++) {
      const s = ((px - 1 - y) * px + x) * 4, d = (y * px + x) * 4, a = buf[s + 3];
      img.data[d + 3] = a;
      for (let k = 0; k < 3; k++) img.data[d + k] = a ? Math.min(255, Math.round((buf[s + k] * 255) / a)) : 0;
    }
  }
  c2.putImageData(img, 0, 0);
  return out;
}

function makeState(el) {
  return {
    el, icon: 0, target: "idle", weights: [1, 0, 0, 0], phase: 0, tm: 0, vt: 0, doneAt: null,
    sp: Object.fromEntries(KEYS.map((k) => [k, { x: 0, v: 0, to: 0, cfg: SPRING.settle }])),
    hover: false, focus: false, sweepAt: -1, nx: 0, ny: 0, stillKey: "", css: 32,
  };
}

const reduced = () => reducedQuery.matches;
const lit = (s) => s.hover || s.focus || s.el.hasAttribute("selected");

function retarget(s) {
  const k = Math.min(1, Math.max(0.3, (s.css - 20) / 52)), still = reduced(), on = lit(s) && !still, move = s.hover && !still, P = s.sp;
  P.yaw.cfg = P.pitch.cfg = move ? SPRING.follow : SPRING.settle;
  P.yaw.to = (on ? POSE.litYaw : 0) - (move ? s.nx * POSE.yaw * k : 0);
  P.pitch.to = (on ? POSE.litPitch : 0) - (move ? s.ny * POSE.pitch * k : 0);
  P.lift.cfg = SPRING.lift;
  P.lift.to = move ? (POSE.liftPx * 1.273) / s.css : 0;
  P.sig.cfg = SPRING.sig;
  P.sig.to = move ? 1 : 0;
  P.lit.cfg = SPRING.lit;
  P.lit.to = lit(s) ? 1 : 0;
  kick();
}

function press(s, on) {
  const p = s.sp.press;
  p.cfg = on ? SPRING.pressIn : SPRING.pressOut;
  p.to = on && !reduced() ? 1 : 0;
  kick();
}

function shaderYaw(s, phase, tm, w) {
  if (s.css < 36) return 0.42 * Math.sin(0.42 * phase) * w[0] + w[1] * 0.36 * Math.sin((2 * Math.PI * tm) / 2.4);
  return 0.42 * Math.sin(0.42 * phase) + w[1] * 0.25 * Math.sin(1.3 * phase);
}
const shaderLift = (tm, w) => 0.012 * Math.sin(1.1 * tm) * w[0];

// Returning to idle resets the clock and phase to the still pose. The difference in yaw and lift, and in their velocity,
// moves into the springs, so the icon settles into its exact still on the settle spring without a jump.
function setState(s, st) {
  if (!STATES.includes(st)) st = "idle";
  if (st === s.target) return;
  if (st === "done") s.doneAt = clock;
  if (st === "idle") {
    const h = 1e-3, w = s.weights, T0 = stillTime(s.icon);
    const rate = w[1] * SPEED[1] + w[2] * SPEED[2] + w[3] * SPEED[3];
    const toward = (wv, ti) => wv.map((x, i) => x + ((i === ti ? 1 : 0) - x) * 7.5 * h);
    const wOld = toward(w, STATES.indexOf(s.target)), wNew = toward(w, 0);
    const yOld = shaderYaw(s, s.phase, s.tm, w), yNew = shaderYaw(s, 0, T0, w);
    const vOld = (shaderYaw(s, s.phase + rate * h, s.tm + (1 - w[0]) * h, wOld) - yOld) / h;
    const vNew = (shaderYaw(s, 0, T0, wNew) - yNew) / h;
    s.sp.yaw.x += yOld - yNew; s.sp.yaw.v += vOld - vNew;
    const lOld = shaderLift(s.tm, w), lNew = shaderLift(T0, w);
    const lvOld = (shaderLift(s.tm + (1 - w[0]) * h, wOld) - lOld) / h, lvNew = (shaderLift(T0, wNew) - lNew) / h;
    s.sp.lift.x += lOld - lNew; s.sp.lift.v += lvOld - lvNew;
    s.phase = 0; s.tm = T0;
  }
  s.target = st;
  s.stillKey = "";
  kick();
}

function step(s, dt) {
  const k = 1 - Math.exp(-dt * 7.5), ti = STATES.indexOf(s.target);
  s.weights = s.weights.map((x, i) => x + ((i === ti ? 1 : 0) - x) * k);
  if (Math.abs(1 - s.weights[ti]) < 2e-4) s.weights = STATES.map((_, i) => (i === ti ? 1 : 0));
  if (s.target !== "idle") {
    const w = s.weights;
    s.phase += dt * (w[1] * SPEED[1] + w[2] * SPEED[2] + w[3] * SPEED[3]);
    s.tm += dt * (1 - w[0]);
    s.vt += dt;
  }
  KEYS.forEach((key) => integrate(s.sp[key], dt));
}

function sweep(s) {
  if (s.sweepAt < 0) return -1;
  const t = (clock - s.sweepAt) / POSE.sweep;
  if (t >= 1) { s.sweepAt = -1; return -1; }
  return -0.45 + 2.25 * easeOut(Math.max(0, t));
}

const settled = (s) => s.weights[STATES.indexOf(s.target)] === 1;
const animating = (s) => s.hover || s.sweepAt >= 0 || KEYS.some((k) => !atRest(s.sp[k]));
const isLive = (s) => (reduced() ? animating(s) : s.target !== "idle" || !settled(s) || animating(s));

function frameParams(s) {
  const P = s.sp, pose = [P.yaw.x, P.pitch.x, P.lift.x, P.press.x], fx = [P.sig.x, P.lit.x, sweep(s), 0];
  if (reduced()) return { ...stillParams(s.icon, s.target), pose, fx };
  let doneT = s.doneAt === null ? 99 : clock - s.doneAt;
  if (doneT > 1.3) doneT = 99;
  return { time: s.tm, phase: s.phase, weights: s.weights, doneT, voice: voiceAt(s.vt) * s.weights[2], pose, fx };
}

function ensureStill(s, dpr) {
  const px = Math.round(s.css * dpr);
  const key = [s.icon, s.target, px, reduced(), KEYS.map((k) => s.sp[k].x.toFixed(4)).join()].join("|");
  if (key === s.stillKey || px < 1) return;
  const P = s.sp;
  render({ name: ICONS[s.icon], size: s.css, scale: dpr, state: s.target, pose: [P.yaw.x, P.pitch.x, P.lift.x, P.press.x], fx: [P.sig.x, P.lit.x, -1, 0], target: s.still });
  s.stillKey = key;
}

function frame(now) {
  raf = 0;
  if (!prog) return;
  const dt = Math.min(0.05, last ? (now - last) / 1000 : 1 / 60);
  last = now;
  clock += dt;
  const dpr = devicePixelRatio || 1, root = document.documentElement;
  const vw = root.clientWidth, vh = root.clientHeight, W = Math.round(vw * dpr), H = Math.round(vh * dpr);
  if (canvas.width !== W || canvas.height !== H) { canvas.width = W; canvas.height = H; canvas.style.width = vw + "px"; canvas.style.height = vh + "px"; }
  const live = [];
  for (const s of visible) {
    step(s, dt);
    s.css = s.el.getBoundingClientRect().width || s.css;
    if (isLive(s)) live.push(s);
    else { ensureStill(s, dpr); s.still.style.visibility = ""; }
  }
  gl.bindFramebuffer(gl.FRAMEBUFFER, null);
  gl.viewport(0, 0, W, H);
  gl.scissor(0, 0, W, H);
  gl.clearColor(0, 0, 0, 0);
  gl.clear(gl.COLOR_BUFFER_BIT);
  for (const s of live) {
    const r = s.el.getBoundingClientRect();
    s.still.style.visibility = "hidden";
    if (r.bottom < 0 || r.top > vh || r.right < 0 || r.left > vw) continue;
    const px = Math.round(r.width * dpr);
    draw(s.icon, Math.round(r.left * dpr), Math.round(H - r.top * dpr - px), px, r.width, frameParams(s));
  }
  if (live.length && !document.hidden) raf = requestAnimationFrame(frame);
  else last = 0;
}

function kick() { if (gl && prog && !raf && !document.hidden) raf = requestAnimationFrame(frame); }
function stop() { if (raf) cancelAnimationFrame(raf); raf = 0; last = 0; }

function pointerXY(s, e) {
  const m = s.el.getBoundingClientRect(), h = s.host.getBoundingClientRect();
  const clamp = (v) => Math.max(-1, Math.min(1, v));
  return [clamp((e.clientX - (m.left + m.width / 2)) / Math.max(h.width / 2, m.width)), clamp((e.clientY - (m.top + m.height / 2)) / Math.max(h.height / 2, m.height / 2))];
}

export class CausticIcon extends HTMLElement {
  static observedAttributes = ["name", "size", "state", "selected", "hover-host"];

  constructor() {
    super();
    const root = this.attachShadow({ mode: "open" });
    root.innerHTML = "<style>:host{display:inline-block;width:32px;height:32px;vertical-align:middle}canvas{display:block;width:100%;height:100%}</style><canvas part=\"icon\"></canvas>";
    this._style = root.querySelector("style");
    this._caustic = makeState(this);
    this._caustic.still = root.querySelector("canvas");
    if (!this.hasAttribute("role")) this.setAttribute("role", "img");
  }

  get name() { return this.getAttribute("name"); }
  set name(v) { this.setAttribute("name", v); }
  get size() { return +(this.getAttribute("size") || 32); }
  set size(v) { this.setAttribute("size", v); }
  get state() { return this.getAttribute("state") || "idle"; }
  set state(v) { this.setAttribute("state", v); }
  get selected() { return this.hasAttribute("selected"); }
  set selected(v) { this.toggleAttribute("selected", !!v); }

  connectedCallback() {
    const s = this._caustic;
    this._apply();
    if (!context()) return;
    icons.add(s);
    io.observe(this);
    this._bind();
  }

  disconnectedCallback() {
    const s = this._caustic;
    icons.delete(s);
    visible.delete(s);
    io?.unobserve(this);
    this._abort?.abort();
    kick();
  }

  attributeChangedCallback(attr) {
    if (!this.isConnected) return;
    if (attr === "hover-host") { this._bind(); return; }
    this._apply();
  }

  _apply() {
    const s = this._caustic, size = this.size;
    this._style.textContent = ":host{display:inline-block;width:" + size + "px;height:" + size + "px;vertical-align:middle}canvas{display:block;width:100%;height:100%}";
    const icon = ICONS.indexOf(this.name);
    if (icon !== s.icon && icon >= 0) { s.icon = icon; s.tm = stillTime(icon); s.stillKey = ""; }
    if (s.tm === 0) s.tm = stillTime(s.icon);
    if (!this.hasAttribute("aria-label")) this.setAttribute("aria-label", ICONS[s.icon]);
    s.css = this.getBoundingClientRect().width || size;
    setState(s, this.state);
    retarget(s);
  }

  _bind() {
    const s = this._caustic, sel = this.getAttribute("hover-host");
    this._abort?.abort();
    this._abort = new AbortController();
    const H = (s.host = (sel && this.closest(sel)) || this), opt = { signal: this._abort.signal };
    H.addEventListener("pointerenter", (e) => { if (e.pointerType === "touch") return; s.hover = true; s.sweepAt = clock; [s.nx, s.ny] = pointerXY(s, e); retarget(s); }, opt);
    H.addEventListener("pointermove", (e) => { if (!s.hover) return; [s.nx, s.ny] = pointerXY(s, e); retarget(s); }, opt);
    H.addEventListener("pointerleave", () => { s.hover = false; press(s, false); retarget(s); }, opt);
    H.addEventListener("pointerdown", (e) => { if (e.button === 0 && e.pointerType !== "touch") press(s, true); }, opt);
    H.addEventListener("pointerup", () => press(s, false), opt);
    H.addEventListener("pointercancel", () => press(s, false), opt);
    H.addEventListener("focusin", (e) => { s.focus = e.target.matches(":focus-visible"); retarget(s); }, opt);
    H.addEventListener("focusout", () => { s.focus = false; retarget(s); }, opt);
  }
}

if (typeof customElements !== "undefined" && !customElements.get("caustic-icon")) customElements.define("caustic-icon", CausticIcon);
