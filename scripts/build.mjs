import { readFileSync, writeFileSync } from "node:fs";

const root = new URL("..", import.meta.url);
const frag = readFileSync(new URL("shader/caustic.frag.glsl", root), "utf8");
writeFileSync(new URL("src/shader.js", root), "export const FRAG = " + JSON.stringify(frag) + ";\n");
