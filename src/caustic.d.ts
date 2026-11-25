export type IconName = "ring" | "grid" | "gem" | "twist" | "slab" | "arch" | "tile" | "stack" | "fan";
export type IconState = "idle" | "thinking" | "speaking" | "done";

export const ICONS: IconName[];
export const STATES: IconState[];

export interface RenderOptions {
  name: IconName;
  size?: number;
  scale?: number;
  state?: IconState;
  ss?: number;
  time?: number;
  phase?: number;
  weights?: [number, number, number, number];
  doneT?: number;
  voice?: number;
  pose?: [number, number, number, number];
  fx?: [number, number, number, number];
  target?: HTMLCanvasElement;
}

export function render(options: RenderOptions): HTMLCanvasElement | null;

export class CausticIcon extends HTMLElement {
  name: IconName;
  size: number;
  state: IconState;
  selected: boolean;
}

declare global {
  interface HTMLElementTagNameMap { "caustic-icon": CausticIcon }
}
