import { state } from "shared";
import { label } from "./label.js";
export function open() { document.querySelector("h1").textContent = label + state.count++; }
