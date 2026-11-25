# notes for agents

caustic is a web component, `<caustic-icon>`, that draws nine glass icons with one shared webgl2 shader.

- import `src/caustic.js` once. it defines the element. react users import `CausticIcon` from `caustic-icons/react`.
- names: ring, grid, gem, twist, slab, arch, tile, stack, fan. states: idle, thinking, speaking, done.
- set `state` to show activity. `done` plays a hop and a glint in about 1.3 s, then you should set it back to `idle`.
- `selected` is for the current or open item. `hover-host` points hover at a parent, like a list row.
- don't create your own canvas or webgl context per icon. the runtime shares one and draws idle icons as stills.
- icons sit on dark backgrounds. they're tuned for #141414 to #1e1e1e.
- without js, use `png/<name>/<name>-<size>[@2x].png`.
- `render({ name, size, scale, state })` returns a canvas if you need a bitmap in code.
- `src/shader.js` is generated from `shader/caustic.frag.glsl` by `npm run build`. edit the glsl, not the js.
