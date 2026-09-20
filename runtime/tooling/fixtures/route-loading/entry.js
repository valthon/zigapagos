import { state } from "shared";
document.querySelector("#open").onclick = async () => {
  const { open } = await import("./pages/settings.js");
  open(state);
};
