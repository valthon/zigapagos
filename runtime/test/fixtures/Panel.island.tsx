import type { Slots } from "@z/runtime";
export interface Props { title: string; children?: any; slots?: Slots }
export default function Panel({ title, children, slots }: Props) {
  return (
    <section>
      <header>{slots?.heading ?? <h2>{title}</h2>}</header>
      <div class="body">{children}</div>
    </section>
  );
}
