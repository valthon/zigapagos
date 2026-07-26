import type { ComponentChildren } from "@z/runtime";
import type { Slots } from "@z/runtime";

export interface Props {
  title: string;
  children?: ComponentChildren;
  slots?: Slots;
}

export default function Panel({ title, children, slots }: Props) {
  return (
    <section class="panel">
      <header>{slots?.heading ?? <h2>{title}</h2>}</header>
      <div class="panel-body">{children}</div>
    </section>
  );
}
