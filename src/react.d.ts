import type { IconName, IconState } from "./caustic.js";

export interface CausticIconProps {
  name: IconName;
  size?: number;
  state?: IconState;
  selected?: boolean;
  hoverHost?: string;
  [key: string]: unknown;
}

export function CausticIcon(props: CausticIconProps): any;
