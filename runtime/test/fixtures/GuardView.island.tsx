import { useGuardData, useFlag, useVariant } from "@z/runtime";
import { host } from "@z/runtime/host";

export interface Props {
  title?: string;
}
type User = { name: string };

// A view that reads every injectable input: props, guard data (useGuardData),
// baked flags (useFlag), experiments (useVariant), and the SSR pathname
// (host.pathname()). Used to exercise `renderForTest`.
export default function GuardView({ title = "untitled" }: Props) {
  const user = useGuardData<User>();
  const promo = useFlag("promoBanner");
  const variant = useVariant("hero");
  return (
    <section>
      <h1>{title}</h1>
      <p class="user">{user ? user.name : "anonymous"}</p>
      <p class="path">{host.pathname()}</p>
      {promo ? <div class="promo">promo</div> : null}
      <p class="variant">{variant || "control"}</p>
    </section>
  );
}
