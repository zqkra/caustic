import { createElement } from "react";
import "./caustic.js";

export function CausticIcon({ name, size, state, selected, hoverHost, ...rest }) {
  return createElement("caustic-icon", { name, size, state, selected: selected ? "" : undefined, "hover-host": hoverHost, ...rest });
}
