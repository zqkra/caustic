// node tools/export.mjs <icon> [--size 256] [--scale 2] [--state idle] [--seconds 0] [--fps 60] [--bg #1e1e1e] [--ss 2] [--out file]
// seconds 0 writes a transparent PNG. Anything above 0 writes an MP4 of the icon in that state.
import { createServer } from "node:http";
import { readFile, writeFile } from "node:fs/promises";
import { spawn } from "node:child_process";
import { extname } from "node:path";
import { chromium } from "playwright-core";

const [name, ...rest] = process.argv.slice(2);
const opt = { size: 256, scale: 2, state: "idle", seconds: 0, fps: 60, bg: "#1e1e1e", ss: 2 };
for (let i = 0; i < rest.length; i += 2) opt[rest[i].replace(/^--/, "")] = rest[i + 1];
for (const k of ["size", "scale", "seconds", "fps", "ss"]) opt[k] = +opt[k];
if (!name) { console.log("usage: node tools/export.mjs <icon> [--size 256] [--scale 2] [--state idle] [--seconds 0] [--out file]"); process.exit(1); }
const video = opt.seconds > 0;
const out = opt.out || name + "-" + opt.state + "-" + opt.size + (video ? ".mp4" : "@" + opt.scale + "x.png");

const root = new URL("..", import.meta.url);
const types = { ".js": "text/javascript", ".html": "text/html" };
const server = createServer(async (req, res) => {
  if (req.url === "/") { res.setHeader("content-type", "text/html"); return res.end("<!doctype html><script type=module>import * as c from '/src/caustic.js'; window.caustic = c;</script>"); }
  try { res.setHeader("content-type", types[extname(req.url)] || "application/octet-stream"); res.end(await readFile(new URL("." + req.url, root))); }
  catch { res.statusCode = 404; res.end(); }
}).listen(0);
await new Promise((r) => server.once("listening", r));

const browser = await chromium.launch({
  executablePath: process.env.CHROME || undefined,
  channel: process.env.CHROME ? undefined : "chromium",
  args: ["--use-angle=swiftshader", "--enable-unsafe-swiftshader", "--ignore-gpu-blocklist", "--disable-gpu-watchdog"],
});
const page = await browser.newPage();
page.on("pageerror", (e) => console.error(String(e)));
await page.goto("http://localhost:" + server.address().port + "/");
await page.waitForFunction(() => window.caustic);

const px = Math.round(opt.size * opt.scale);
if (!video) {
  const url = await page.evaluate((o) => caustic.render({ name: o.name, size: o.size, scale: o.scale, state: o.state, ss: o.ss }).toDataURL("image/png"), { ...opt, name });
  await writeFile(out, Buffer.from(url.split(",")[1], "base64"));
} else {
  const ff = spawn("ffmpeg", ["-y", "-loglevel", "error", "-f", "rawvideo", "-pix_fmt", "rgba", "-s", px + "x" + px, "-framerate", String(opt.fps), "-i", "-",
    "-vf", "noise=alls=2:allf=t,format=yuv420p", "-c:v", "libx264", "-preset", "slow", "-crf", "14", "-movflags", "+faststart", out], { stdio: ["pipe", "inherit", "inherit"] });
  const speed = { idle: 1, thinking: 2.6, speaking: 1.6, done: 0.6 }[opt.state] ?? 1;
  const n = Math.round(opt.seconds * opt.fps);
  for (let i = 0; i < n; i++) {
    const t = i / opt.fps;
    const b64 = await page.evaluate(({ o, name, t, speed }) => {
      const i = caustic.STATES.indexOf(o.state), seed = (caustic.ICONS.indexOf(name) * 0.618034 + 0.137) % 1;
      const frame = o.state === "idle" ? {} : { time: 2.2 + seed * 7 + t, phase: t * speed, doneT: o.state === "done" ? t : 99 };
      const c = caustic.render({ name, size: o.size, scale: o.scale, state: o.state, ss: o.ss, ...frame });
      const out = document.createElement("canvas"); out.width = c.width; out.height = c.height;
      const x = out.getContext("2d"); x.fillStyle = o.bg; x.fillRect(0, 0, c.width, c.height); x.drawImage(c, 0, 0);
      const d = x.getImageData(0, 0, c.width, c.height).data;
      let s = ""; for (let j = 0; j < d.length; j += 0x8000) s += String.fromCharCode.apply(null, d.subarray(j, j + 0x8000));
      return btoa(s);
    }, { o: opt, name, t, speed });
    if (!ff.stdin.write(Buffer.from(b64, "base64"))) await new Promise((r) => ff.stdin.once("drain", r));
  }
  ff.stdin.end();
  await new Promise((r) => ff.on("close", r));
}
await browser.close();
server.close();
console.log(out);
