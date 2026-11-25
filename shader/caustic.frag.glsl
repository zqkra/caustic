#version 300 es
precision highp float;
uniform vec2  uOrigin;   // slot bottom-left in device px
uniform vec2  uRes;      // slot size in device px
uniform float uSize;     // slot size in CSS px (28, 72, 96 ...); use it for level of detail
uniform float uTime;     // seconds, monotonic
uniform float uPhase;    // per-slot phase: advances faster while thinking/speaking, never jumps
uniform vec4  uState;    // eased weights: x idle, y thinking, z speaking, w done (sum ~ 1)
uniform float uDoneT;    // seconds since the slot entered done (99 when not done)
uniform float uVoice;    // 0..1 speaking envelope (syllables), already multiplied by speaking weight
uniform float uIcon;     // 0 ring, 1 grid, 2 gem, 3 twist, 4 slab, 5 arch, 6 tile, 7 stack, 8 fan
uniform float uSeed;     // icon seed in [0,1)
uniform int   uSS;       // supersampling per axis
uniform vec4  uPose;     // pointer pose from the runtime springs: x yaw (rad), y pitch (rad), z lift (object units), w press 0..1
uniform vec4  uFx;       // x per-form signature 0..1, y lit (selected or focused) 0..1, z light-sweep position (-1 = off)
out vec4 outColor;

#define PI 3.14159265
#define TAU 6.2831853
#define IC(i) (abs(uIcon - float(i)) < 0.5)

float hash(uvec2 p){ uint x = p.x + p.y*0x9E3779B9u; x ^= x >> 16; x *= 0x7feb352du; x ^= x >> 15; x *= 0x846ca68bu; x ^= x >> 16; return float(x)*(1.0/4294967296.0); }
// pixel width in p-space, for analytic antialiasing
float px(){ return 2.0/uRes.x; }
// Dark studio: black room, one big overhead softbox, a key strip at left, a faint rim at right.
float _box(vec3 d, vec3 c, vec3 up, vec2 size, float soft){
  float k = dot(d,c); if(k<=0.0) return 0.0;
  vec3 r = normalize(cross(up,c)); vec3 u = cross(c,r);
  vec2 q = vec2(dot(d,r), dot(d,u))/k;
  vec2 e = smoothstep(size, size*(1.0-soft) , abs(q));
  return e.x*e.y;
}
vec3 studio(vec3 d){
  vec3 c = vec3(0.006) + vec3(0.018)*smoothstep(-0.2,1.0,d.y);
  c += vec3(1.00,1.00,1.02)*3.2*_box(d, normalize(vec3(-0.35,0.85,0.45)), vec3(0,0,-1), vec2(0.55,0.32), 0.5);
  c += vec3(0.95,0.97,1.00)*1.6*_box(d, normalize(vec3(-0.95,0.15,0.35)), vec3(0,1,0), vec2(0.07,0.9), 0.6);
  c += vec3(0.90,0.94,1.00)*0.9*_box(d, normalize(vec3(0.9,0.25,-0.2)), vec3(0,1,0), vec2(0.05,0.7), 0.6);
  c += vec3(0.02)*smoothstep(0.0,-0.4,d.y);
  return c;
}
float fresnel(float cosT, float f0){ return f0 + (1.0-f0)*pow(1.0-clamp(cosT,0.0,1.0),5.0); }
// Filmic tone curve: an in-house least-squares fit (see NOTICE).
vec3 tone(vec3 x){ vec3 t = pow(max(x, 0.0), vec3(1.42806)); return clamp(pow(t/(t + 0.20497), vec3(1.11185))*1.00499, 0.0, 1.0); }

float fBox(vec3 p, vec3 b, float r){ vec3 q = abs(p) - (b - r); return length(max(q,0.0)) + min(max(q.x,max(q.y,q.z)),0.0) - r; }
float fRoundCyl(vec3 p, float ra, float h, float r){ vec2 d = vec2(length(p.xz) - ra + r, abs(p.y) - h + r); return min(max(d.x,d.y),0.0) + length(max(d,0.0)) - r; }
float fSquircle2(vec2 p, float s){ vec2 a = abs(p)/s; return (pow(pow(a.x,4.0)+pow(a.y,4.0),0.25) - 1.0)*s; }
float fExtrude(float d2, float z, float h, float r){ vec2 w = vec2(d2 + r, abs(z) - h + r); return min(max(w.x,w.y),0.0) + length(max(w,0.0)) - r; }
float fHex2(vec2 p, float r){ const vec3 k = vec3(-0.866025404,0.5,0.577350269); p = abs(p); p -= 2.0*min(dot(k.xy,p),0.0)*k.xy; p -= vec2(clamp(p.x,-k.z*r,k.z*r), r); return length(p)*sign(p.y); }

// Pose shared by every mark: a 3/4 yaw that sways (faster while thinking), a lift on voice, a hop on done,
// plus the pointer pose from the runtime springs (uPose: x yaw, y pitch, z lift, w press 0..1).
// Below 24 px, thinking is a calm 2.4 s swing that loops exactly.
float formSmall(){ return 1.0 - step(36.0, uSize); }
// 28 px and under: a rest pose and framing tuned per form so each icon reads at that size.
float formTiny(){ return 1.0 - step(36.0, uSize); }
float formLift(){
  float hop = uState.w * 0.07 * sin(clamp(uDoneT/0.55, 0.0, 1.0)*PI) * step(uDoneT, 0.55) * (1.0 - 0.6*formTiny());
  return 0.012*sin(uTime*1.1) * uState.x + 0.03*uVoice + hop + uPose.z;
}
float formYaw(){
  float big = 0.55 + 0.42*sin(uPhase*0.42) + uState.y*0.25*sin(uPhase*1.3);
  float small = 0.55 + 0.42*sin(uPhase*0.42)*uState.x + uState.y*0.36*sin(TAU*uTime/2.4);
  float tinyYaw = IC(3) ? 0.6 : (IC(0) ? -0.4 : 0.0);
  return mix(big, small, formSmall()) + tinyYaw*formTiny() + uPose.x;
}
float formScale(){ return 1.0 - 0.03*uPose.w; }
// World to object: lift, press scale about the base, pitch about a pivot low in the body, then yaw.
vec3 formSpace(vec3 p){
  p.y -= formLift();
  p /= formScale();
  p.y -= 0.25; float cp = cos(uPose.y), sp = sin(uPose.y); p.yz = mat2(cp, sp, -sp, cp) * p.yz; p.y += 0.25;
  float a = formYaw(); float c = cos(a), s = sin(a);
  p.xz = mat2(c, -s, s, c) * p.xz;
  if (IC(0)) { vec2 r = p.xy - vec2(0.0, 0.45); float ra = 0.12*uFx.x; float cr = cos(ra), sr = sin(ra); p.xy = mat2(cr, -sr, sr, cr)*r + vec2(0.0, 0.45); }
  return p;
}
// The same rotations for a direction (light vectors into object space).
vec3 formDir(vec3 d){
  float cp = cos(uPose.y), sp = sin(uPose.y); d.yz = mat2(cp, sp, -sp, cp) * d.yz;
  float a = formYaw(); float c = cos(a), s = sin(a); d.xz = mat2(c, -s, s, c) * d.xz;
  return d;
}

// The nine forms.
float sdForm(vec3 p){
  float d = 1e3;
  if (IC(0)) {                                   // ring: an upright ring with a squared, softened section. Hover: it rolls on its axis (formSpace).
    vec3 q = p - vec3(0.0, 0.45, 0.0);
    vec2 s = vec2(length(q.xy) - 0.31, q.z);
    d = length(max(abs(s) - vec2(0.085, 0.085), 0.0)) + min(max(abs(s.x)-0.085, abs(s.y)-0.085), 0.0) - 0.04;
  } else if (IC(1)) {                            // grid: a block cut into a 2x2 grid of cells by two shallow grooves. Hover: the cells part by a hair.
    vec3 q = p - vec3(0.0, 0.3, 0.0);
    d = fBox(q, vec3(0.3), 0.07);
    float g = min(abs(q.x), abs(q.z)) - (0.012 + 0.007*uFx.x);
    d = max(d, -max(g, q.y - (0.24 - 0.07*uFx.x)));
  } else if (IC(2)) {                            // gem: a cut gem on its point, a hexagonal bipyramid with a crisp girdle. Hover: a facet catches a sparkle (shading).
    vec3 q = p - vec3(0.0, 0.44, 0.0);
    float r = length(q.xz);
    float a = atan(q.z, q.x); float sec = TAU/6.0; float am = mod(a + sec*0.5, sec) - sec*0.5;
    float rr = r*cos(am);
    float top = max(rr*0.62 + q.y - 0.17, -q.y);
    float bot = max(rr*1.05 - q.y - 0.44, q.y);
    d = min(top, bot)*0.8;
    d = max(d, rr - 0.3);
  } else if (IC(3)) {                            // twist: a chamfered triangular column with a uniform third-turn twist, flat square caps, phased so the 3/4 view is symmetric. Hover: it untwists slightly.
    vec3 q = p - vec3(0.0, 0.440, 0.0);
    float w = clamp(q.y/0.88 + 0.5, 0.0, 1.0);
    float tw = 2.0943951*(1.0 - 0.16*uFx.x)*(w - 0.5) + -0.5235988;
    float c = cos(tw), sn = sin(tw);
    vec2 t = mat2(c,-sn,sn,c)*q.xz;
    const float k = 1.7320508; const float r = 0.185;
    t.x = abs(t.x) - r; t.y = t.y + r/k;
    if (t.x + k*t.y > 0.0) t = vec2(t.x - k*t.y, -k*t.x - t.y)/2.0;
    t.x -= clamp(t.x, -2.0*r, 0.0);
    float tri = -length(t)*sign(t.y);
    d = fExtrude(tri - 0.035, q.y, 0.440, 0.035)*0.7;
  } else if (IC(4)) {                            // slab: a tall, thick upright slab, portrait proportion. Hover: it tips back on its bottom edge.
    vec3 q = p - vec3(0.0, 0.0, -0.075); float ta = 0.10*uFx.x; float ct = cos(ta), st = sin(ta);
    q.yz = mat2(ct, -st, st, ct)*q.yz; q.z += 0.075;
    d = fBox(q - vec3(0.0, 0.43, 0.0), vec3(0.27, 0.43, 0.075), 0.045);
  } else if (IC(5)) {                            // arch: an arch, like the counter of a letter. Hover: it rocks onto one leg and back.
    vec3 q = p - vec3(-0.235, 0.0, 0.0); float ra = -0.09*sin(PI*uFx.x); float cr = cos(ra), sr = sin(ra);
    q.xy = mat2(cr, -sr, sr, cr)*q.xy; q.x -= 0.235;
    vec2 xy = q.xy - vec2(0.0, 0.42);
    float outer = (xy.y > 0.0) ? length(xy) - 0.33 : abs(xy.x) - 0.33;
    float inner = (xy.y > 0.0) ? length(xy) - 0.14 : abs(xy.x) - 0.14;
    float d2 = max(outer, -inner);
    d2 = max(d2, -q.y);
    d = fExtrude(d2, q.z, 0.14, 0.04);
  } else if (IC(6)) {                            // tile: an upright squircle tile, thick like a block of glass. Hover: its faces press in.
    vec3 q = p - vec3(0.0, 0.36, 0.0);
    float dent = 0.016*uFx.x*exp(-dot(q.xy, q.xy)/0.06);
    d = fExtrude(fSquircle2(q.xy, 0.33), q.z, 0.11 - dent, 0.05);
  } else if (IC(7)) {                            // stack: three landscape slabs stacked in a gentle step. Hover: they fan out a step.
    for (int i = 0; i < 3; i++) { float fi = float(i);
      vec3 q = p - vec3((-0.05 + 0.05*fi)*(1.0 + 0.9*uFx.x), 0.07 + 0.135*fi, (0.04 - 0.04*fi)*(1.0 + 0.9*uFx.x));
      float ya = (fi - 1.0)*0.10*uFx.x; float cy = cos(ya), sy = sin(ya); q.xz = mat2(cy, -sy, sy, cy)*q.xz;
      d = min(d, fBox(q, vec3(0.34, 0.06, 0.22), 0.04)); }
  } else {                                        // fan: three tiles fanned from one pivot. Hover: the fan spreads.
    for (int i = 0; i < 3; i++) { float fi = float(i) - 1.0;
      vec3 q = p - vec3(0.0, 0.02, 0.06*fi);
      float a = fi*0.42*(1.0 + 0.32*uFx.x); float c = cos(a), sn = sin(a);
      q.xy = mat2(c, sn, -sn, c)*q.xy;
      d = min(d, fBox(q - vec3(0.0, 0.36, 0.0), vec3(0.17, 0.3, 0.035), 0.03)); }
    d = max(d, -p.y);
  }
  return d;
}
// Palette: each icon has a primary hue (A), a secondary (B) and an accent (C). Linear RGB.
void formPalette(out vec3 A, out vec3 B, out vec3 C){
  if (IC(0)) { A = vec3(0.24,0.22,1.00); B = vec3(0.55,0.42,1.00); C = vec3(1.00,0.78,0.42); }        // ring: indigo, blue-violet and champagne
  else if (IC(1)) { A = vec3(0.04,0.16,0.95); B = vec3(0.05,0.60,1.00); C = vec3(0.55,0.85,1.00); } // grid: cobalt, cyan
  else if (IC(2)) { A = vec3(0.40,0.08,0.85); B = vec3(0.95,0.18,0.75); C = vec3(0.75,0.55,1.00); } // gem: amethyst, magenta
  else if (IC(3)) { A = vec3(1.00,0.32,0.04); B = vec3(1.00,0.08,0.06); C = vec3(1.00,0.70,0.25); } // twist: tangerine, coral red
  else if (IC(4)) { A = vec3(0.85,0.02,0.08); B = vec3(1.00,0.30,0.45); C = vec3(1.00,0.55,0.40); } // slab: ruby, pink
  else if (IC(5)) { A = vec3(1.00,0.55,0.05); B = vec3(1.00,0.82,0.30); C = vec3(0.80,0.30,0.04); } // arch: amber, honey gold
  else if (IC(6)) { A = vec3(0.02,0.62,0.25); B = vec3(0.40,0.95,0.45); C = vec3(0.10,0.85,0.70); } // tile: emerald, mint
  else if (IC(7)) { A = vec3(0.02,0.55,0.62); B = vec3(0.30,0.90,0.95); C = vec3(0.10,0.40,0.95); } // stack: teal, aquamarine
  else { A = vec3(1.00,0.30,0.45); B = vec3(1.00,0.62,0.45); C = vec3(0.90,0.20,0.60); }            // fan: rose, apricot
}
// Shared camera: slightly above, looking down about 16 degrees at the form.
// 32 px and below: each form is framed so its visual centroid sits on the slot
// centre and every mark carries the same visual weight (geometric mean of sqrt(area) and height): 0.72 of the slot in rows
// (28 to 35 px) and 0.563 in status sizes (below 24 px). A form is capped where its largest half-extent over every hover,
// thinking, speaking and done pose would reach the outer 2 device px plus 1.6 px of antialiasing, so nothing is ever clipped.
// xy: rest centroid in slot space, z: weight, w: max half-extent (rows); eS: (status sizes).
vec3 tinyFrame(){
  vec4 f; float eS;
  if(IC(0)){ f = vec4(0.0049, 0.0233, 0.6658, 0.4258); eS = 0.4563; }
  else if(IC(1)){ f = vec4(-0.0070, -0.2009, 0.5916, 0.3629); eS = 0.3853; }
  else if(IC(2)){ f = vec4(0.0058, -0.1670, 0.4481, 0.3050); eS = 0.3330; }
  else if(IC(3)){ f = vec4(-0.0018, 0.0281, 0.6236, 0.4234); eS = 0.4737; }
  else if(IC(4)){ f = vec4(0.1384, 0.0857, 0.6009, 0.3944); eS = 0.4336; }
  else if(IC(5)){ f = vec4(0.0318, -0.1018, 0.5908, 0.3712); eS = 0.4231; }
  else if(IC(6)){ f = vec4(0.0283, -0.1064, 0.5597, 0.3422); eS = 0.3782; }
  else if(IC(7)){ f = vec4(0.0102, -0.3531, 0.4699, 0.4114); eS = 0.4229; }
  else { f = vec4(0.0422, -0.0678, 0.5164, 0.3617); eS = 0.3690; }
  bool st = uSize < 24.0;
  float s = min((st ? 0.563 : 0.72)/f.z, (0.5 - 3.6/uRes.x)/(st ? eS : f.w));
  return vec3(f.xy, s);
}
void formCamera(vec2 p, out vec3 ro, out vec3 rd){
  if(formTiny() > 0.5){ vec3 f = tinyFrame(); p = p/f.z + f.xy; }
  vec3 ta = vec3(0.0, 0.41, 0.0);
  ro = ta + vec3(0.0, 0.62, 2.6);
  vec3 fw = normalize(ta - ro), rt = normalize(cross(fw, vec3(0,1,0))), up = cross(rt, fw);
  rd = normalize(fw*4.2 + rt*p.x + up*p.y);
}

float pMap(vec3 p){ return sdForm(formSpace(p))*formScale(); }
vec3 pNrm(vec3 p){ const vec2 e = vec2(0.0012,-0.0012); return normalize(e.xyy*pMap(p+e.xyy)+e.yyx*pMap(p+e.yyx)+e.yxy*pMap(p+e.yxy)+e.xxx*pMap(p+e.xxx)); }
vec3 pEnv(vec3 d){
  vec3 c = studio(d);
  float bk = max(dot(d, normalize(vec3(0.25,0.35,-1.0))), 0.0);
  c += vec3(0.95,0.97,1.0)*(0.9*pow(bk, 8.0) + 0.10*pow(bk, 2.0));
  c += vec3(0.010)*smoothstep(0.0,-0.3,d.y);
  return c*(1.0 + 0.28*uFx.y);
}
float pSoft(vec3 g, vec3 L, float w, int N){
  float t = 0.0, T = 0.0, dt = w*0.3;
  for(int i=0;i<160;i++){
    if(i>=N) break;
    float d = pMap(g + L*t);
    if(d > w*1.5){ t += (d - w)*0.85; }
    else if(d < -w*1.5){ float st = (-d - w)*0.85; T += st; t += st; }
    else { T += smoothstep(w, -w, d)*dt; t += dt; }
    if(t > 2.2) break;
  }
  return T;
}
float pInner(vec3 X, vec3 dir, int N, out vec3 E){
  float T = 0.0, tt = 0.0;
  for(int i=0;i<56;i++){
    if(i>=N) break;
    float d = pMap(X + dir*tt);
    if(d > 0.0){ T = tt - d; break; }
    tt += max(-d, 0.003); T = tt;
  }
  E = X + dir*T;
  return T;
}

vec4 mark(vec2 p){
  vec3 A, B, C; formPalette(A, B, C);
  if(IC(4)){ A = vec3(0.80,0.02,0.07); B = vec3(0.92,0.06,0.10); C = vec3(1.00,0.36,0.30); }
  if(IC(8)){ A = vec3(1.00,0.10,0.34); B = vec3(1.00,0.52,0.22); C = vec3(1.00,0.70,0.40); }
  float hiQ = step(40.0, uSize);
  vec3 Ab = A;
  float dens = IC(8) ? 9.0 : (IC(7) ? 2.8 : (IC(0) ? 6.0 : (IC(4) ? 6.0 : (IC(6) ? 2.4 : (IC(3) ? 4.5 : 2.0)))));
  vec3 sig = -log(clamp(Ab, 0.02, 1.0))*dens;
  vec3 ro, rd; formCamera(p, ro, rd);
  float pw = px()*0.64;
  int NM = uSize < 40.0 ? 56 : 96;

  float t = 1.6, minD = 1e3, tMin = 1.6; bool hit = false;
  for(int i=0;i<96;i++){
    if(i>=NM) break;
    float d = pMap(ro + rd*t);
    if(d < minD){ minD = d; tMin = t; }
    if(d < 0.0006){ hit = true; break; }
    t += d; if(t > 4.5) break;
  }
  float cov = hit ? 1.0 : clamp(1.0 - minD/pw, 0.0, 1.0);

  vec4 tab = vec4(0.0);
  float tf = -ro.y/rd.y;
  float tiny = 1.0 - step(30.0, uSize);
  // Every table effect fades to zero inside the slot: a soft screen-space window, so nothing is ever clipped by the slot edge.
  vec2 ep = abs(p);
  float e0 = 1.0 - 5.0/uRes.x;
  float win = smoothstep(e0, e0 - 0.27, ep.x)*smoothstep(e0, e0 - 0.27, ep.y);
  if(cov < 1.0 && tf > 0.0 && win > 0.0){
    vec3 g = ro + rd*tf;
    if(tiny > 0.5){
      // 28 px and below: a tight, soft contact shadow centred under the object, and no coloured glow.
      float dg = pMap(g + vec3(0.0, 0.03, 0.0));
      float cs = exp(-max(dg, 0.0)/0.045)*0.42;
      tab = vec4(vec3(0.0), cs*win);
    } else {
      vec3 Lc = normalize(vec3(0.14,0.86,-0.46));
      vec3 Lk = normalize(vec3(-0.5,0.9,0.4));
      int NT = uSize < 40.0 ? 48 : 128;
      float wc = uSize < 40.0 ? 0.09 : 0.07;
      float Tc = pSoft(g, Lc, wc, NT);
      float Tk = pSoft(g, Lk, wc*1.15, NT);
      float ks = exp(-Tk*9.0);
      float occ = 0.0;
      for(int i=1;i<5;i++){ float hh = 0.035*float(i); occ += clamp((hh - pMap(g + vec3(0,hh,0)))/hh, 0.0, 1.0); }
      occ *= 0.25;
      float fall = smoothstep(1.05, 0.35, length(g.xz - vec2(0.05, 0.0)));
      vec3 pc = A*A/max(A.r, max(A.g, A.b));
      vec3 I = vec3(1.0 + 0.35*uVoice);
      float foot = 1.0 - exp(-Tc*6.0);
      vec3 pool = pc*foot*0.09;
      vec3 hot = vec3(0.0);
      if(hiQ > 0.5){
        float sm = smoothstep(72.0, 200.0, uSize);
        vec3 hc;
        if(IC(0)){
          vec3 gq = formSpace(g);
          vec3 Lq = formDir(Lc);
          vec3 h = gq - Lq*(gq.z/Lq.z);
          float dc = length(h.xy - vec2(0.0, 0.45)) - 0.31;
          float wl = mix(0.022, 0.012, sm) + 0.9*tf/uRes.x;
          hc = vec3(exp(-pow((dc + 0.006)/wl, 2.0)), exp(-pow(dc/wl, 2.0)), exp(-pow((dc - 0.006)/wl, 2.0)))*smoothstep(0.05, 0.25, Tc)*smoothstep(0.12, 0.30, abs(Lq.z));
        } else {
          // One coherent light shape: the light focused through the glass, brightest where the light path crosses the most glass,
          // so it takes the object's own silhouette, cast along the light, with soft edges and a slight dispersion fringe.
          hc = vec3(smoothstep(0.05, 0.42, Tc), smoothstep(0.07, 0.46, Tc), smoothstep(0.09, 0.50, Tc));
          hc *= hc*0.62;
        }
        vec3 hcol = IC(0) ? mix(C, vec3(1.0), 0.2*sm) : mix(pc, vec3(1.0), 0.15);
        hot = hc*hcol*0.30*mix(1.55, 1.0, sm);
      }
      vec3 glow = (pool + hot)*I*fall*(1.0 + 0.45*uFx.y);
      float shA = clamp(0.34*(1.0 - ks) + 0.55*occ, 0.0, 0.75)*fall;
      float ga = clamp(max(glow.r, max(glow.g, glow.b))*2.2, 0.0, 0.95);
      float a = max(shA, ga)*win;
      tab = vec4(a > 0.0 ? glow/max(max(shA, ga), 1e-3)*1.4 : vec3(0.0), a);
    }
  }

  vec4 obj = vec4(0.0);
  if(cov > 0.0){
    if(!hit) t = tMin;
    vec3 P = ro + rd*t;
    vec3 n = pNrm(P);
    vec3 v = -rd;
    float cosT = clamp(dot(n, v), 0.0, 1.0);
    float Fr = fresnel(cosT, 0.045);
    vec3 r = reflect(rd, n);
    vec3 refl = pEnv(r);
    vec3 rin = refract(rd, n, 1.0/1.5);
    vec3 X = P - n*0.003;
    int NI = uSize < 40.0 ? 28 : 56;
    vec3 E; float T = pInner(X, rin, NI, E);
    vec3 nE = pNrm(E);
    vec3 trans;
    for(int c=0;c<3;c++){
      float eta = 1.5 + (float(c) - 1.0)*0.035*hiQ;
      vec3 o = refract(rin, -nE, eta);
      float tir = dot(o,o) < 0.5 ? 1.0 : 0.0;
      if(tir > 0.5) o = reflect(rin, -nE);
      vec3 e = pEnv(o)*(tir > 0.5 ? 0.45 : 1.0);
      trans[c] = c==0 ? e.r : (c==1 ? e.g : e.b);
    }
    vec3 absT = IC(0) ? sig*T : sig*(T + (IC(8) ? 0.05 : 0.0));
    if(IC(0)) trans = trans*trans*1.7;
    trans *= exp(-absT);
    if(IC(0) && hiQ > 0.5){
      vec3 ir = reflect(rin, -nE);
      float cosE = clamp(dot(rin, nE), 0.0, 1.0);
      float tirE = dot(refract(rin, -nE, 1.5), vec3(1.0)) == 0.0 ? 1.0 : 0.0;
      vec3 E2; float T2 = pInner(E - nE*0.003, ir, NI, E2);
      vec3 nE2 = pNrm(E2);
      vec3 o2 = refract(ir, -nE2, 1.5);
      if(dot(o2,o2) < 0.5) o2 = reflect(ir, -nE2);
      float Tt = T + T2;
      vec3 e2 = pEnv(o2)*exp(-sig*Tt);
      float wI = max(tirE, 0.30 + 0.5*fresnel(cosE, 0.04));
      trans = mix(trans, e2*1.25, wI*0.55);
    }
    vec3 Lk = normalize(vec3(-0.5,0.9,0.4));
    float key = clamp(dot(n, Lk)*0.5 + 0.5, 0.0, 1.0);
    if(IC(8)){ refl *= mix(vec3(1.0), A, 0.55); Fr *= 0.6; }
    vec3 glow = (IC(0) ? A*0.6 : A)*(0.05 + 0.20*key)*(1.0 - exp(-T*2.0))*exp(-sig*T*0.35);
    vec3 col = (trans + glow)*(1.0 - Fr) + refl*Fr*(IC(0) ? 0.35 : 1.0);
    if(IC(8)){
      float mx = max(col.r, max(col.g, col.b)), mn = min(col.r, min(col.g, col.b));
      float sat = (mx - mn)/max(mx, 1e-4);
      vec3 rose = A*dot(col, vec3(0.2126,0.7152,0.0722))/dot(A, vec3(0.2126,0.7152,0.0722));
      col = mix(col, rose, smoothstep(0.82, 0.35, sat)*0.9 + 0.1*step(col.r, col.b + 0.05));
    }

    float edge = 0.0;
    if(hiQ > 0.5){
      float ce = IC(0) ? 0.03 : 0.02;
      float lapS = (pMap(P+vec3(ce,0,0))+pMap(P-vec3(ce,0,0))+pMap(P+vec3(0,ce,0))+pMap(P-vec3(0,ce,0))+pMap(P+vec3(0,0,ce))+pMap(P-vec3(0,0,ce)) - 6.0*pMap(P))/(ce*ce);
      edge = IC(0) ? smoothstep(1.2, 10.0, lapS) : smoothstep(3.0, 24.0, lapS);
    } else {
      edge = smoothstep(0.55, 0.95, 1.0 - cosT)*0.7;
    }
    vec3 q = formSpace(P);
    float ph = (1.0 - cosT)*2.4 + 0.5*sin(formYaw()*2.2 + dot(q, vec3(2.1,3.3,1.7))) + 0.35*uVoice;
    float dm = smoothstep(0.1, 0.9, 0.5 + 0.5*sin(ph*2.2 - 0.8));
    if(IC(0)) dm = 0.35 + 0.65*dm;
    if(IC(8)) dm *= 0.45;
    vec3 dich = mix(B, C, dm);
    float rimT = pow(1.0 - cosT, 2.5)*clamp(dot(n, normalize(vec3(0.9,0.3,-0.35)))*0.6 + 0.4, 0.0, 1.0);
    vec3 dR = dich*(pEnv(r)*1.1 + 0.07 + 0.55*rimT);
    col = mix(col, dR + col*0.25, edge*(IC(0) ? 0.92 : 0.85));
    float sw = 0.0;
    if(uFx.z > -0.9) sw += exp(-pow((p.x*0.5 + 0.5 + 0.35*(p.y*0.5 + 0.5) - uFx.z)*6.0, 2.0));
    if(formSmall() > 0.5) sw += uState.y*0.5*exp(-pow((p.x*0.5 + 0.5 + 0.35*(p.y*0.5 + 0.5) - (fract(uTime/2.4)*2.25 - 0.45))*5.0, 2.0));
    col += dich*sw*(edge*1.2 + 0.05 + 0.12*(1.0 - hiQ));
    if(IC(2)){
      vec3 sv = vec3(0.0, 0.44, 0.30);
      vec3 dq = q - sv; float sp = (exp(-dot(dq, dq)/0.0009) + 0.35*exp(-dot(dq, dq)/0.006))*4.0*uFx.x*(1.0 - uFx.x);
      col += (C*0.5 + 0.9)*sp*2.6;
    }
    if(uDoneT < 1.3){
      float s = mix(-0.05, 1.0, clamp(uDoneT/0.95, 0.0, 1.0));
      float gl = exp(-pow((q.y - s)*13.0, 2.0))*max(edge, 0.25)*uState.w*(1.0 - smoothstep(0.95, 1.3, uDoneT));
      col += (C*0.6 + 0.6)*gl*2.2;
    }
    obj = vec4(col, cov);
  }
  float Ao = obj.a + tab.a*(1.0 - obj.a);
  vec3 Co = Ao > 0.0 ? (obj.rgb*obj.a + tab.rgb*tab.a*(1.0 - obj.a))/Ao : vec3(0.0);
  return vec4(Co, Ao);
}

void main(){
  vec2 fc = floor(gl_FragCoord.xy - uOrigin);
  vec4 acc = vec4(0.0);
  for(int j=0;j<4;j++){ if(j>=uSS) break;
    for(int i=0;i<4;i++){ if(i>=uSS) break;
      vec2 o = (vec2(float(i),float(j))+0.5)/float(uSS);
      vec2 p = (fc + o)/uRes*2.0 - 1.0;
      vec4 c = mark(p);
      c.rgb = pow(tone(c.rgb), vec3(1.0/2.2));
      acc += vec4(c.rgb*c.a, c.a);
    }
  }
  vec4 o = acc/float(uSS*uSS);
  uvec2 q = uvec2(gl_FragCoord.xy); uint f = uint(fract(uTime)*1000.0);
  float dn = (hash(q + uvec2(f*1997u, f*7919u)) + hash(q.yx + 7919u) - 1.0)/255.0;
  o.rgb = clamp(o.rgb + dn*o.a, 0.0, o.a);
  outColor = o;
}
