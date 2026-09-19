import type { ComponentChildren } from "@z/runtime";

export interface ButtonProps {
  children: ComponentChildren;
  pressed: boolean;
  onClick: () => void;
}

// A normal reusable Preact component, with no island directives or CSS loader.
export function Button({ children, pressed, onClick }: ButtonProps) {
  return <button type="button" class="ds-button" aria-pressed={pressed} onClick={onClick}>{children}</button>;
}
