import { Router, Link, useNavigate, useState, useEffect, useRef, type ComponentChildren } from "@z/runtime";
import { storage, type Task } from "./storage";
import { TasksContext, useTasks } from "./store";

export const spa = {
  base: "/app",
  title: "My tasks",
  head: [{ rel: "stylesheet", href: "/style.css" }],
};

function Frame({ children }: { children: ComponentChildren }) {
  return <>
    <a class="skip-link" href="#main">Skip to content</a>
    <nav aria-label="Application"><Link href="/">Tasks</Link><Link href="/new">New task</Link><Link href="/about">About</Link><a href="/">Site home</a></nav>
    <noscript><p>This application needs JavaScript. The <a href="/">site homepage</a> works without it.</p></noscript>
    <main id="main">{children}</main>
  </>;
}

function Tasks() {
  const model = useTasks();
  const [failure, setFailure] = useState("");
  async function toggle(task: Task) {
    setFailure("");
    try { await model.save(model.tasks.map(item => item.id === task.id ? { ...item, done: !item.done } : item)); }
    catch { setFailure("Could not save the change. Your tasks are unchanged; try again."); }
  }
  return <Frame>
    <h1>My tasks</h1>
    <p>This demo saves tasks in this browser only.</p>
    {model.phase === "loading" && <p role="status">Loading tasks…</p>}
    {model.phase === "error" && <section><p role="alert">{model.error}</p><button type="button" onClick={model.reload}>Retry loading</button></section>}
    {model.phase === "ready" && <>
      {model.tasks.length === 0 ? <p>No tasks yet. <Link href="/new">Create your first task</Link>.</p> :
        <ul class="tasks">{model.tasks.map(task => <li key={task.id}><label><input type="checkbox" checked={task.done} disabled={model.busy} onChange={() => void toggle(task)} /> <span>{task.title}</span></label></li>)}</ul>}
      {model.busy && <p role="status">Saving…</p>}
      {failure && <p role="alert">{failure}</p>}
    </>}
  </Frame>;
}

function NewTask() {
  const model = useTasks();
  const navigate = useNavigate();
  const [title, setTitle] = useState("");
  const [invalid, setInvalid] = useState(false);
  const [failure, setFailure] = useState("");
  const input = useRef<HTMLInputElement>(null);
  async function submit(event: Event) {
    event.preventDefault();
    const clean = title.trim();
    setInvalid(!clean);
    setFailure("");
    if (!clean) { input.current?.focus(); return; }
    if (model.phase !== "ready" || model.busy) return;
    try {
      // getRandomValues also works on HTTP LAN previews, unlike randomUUID.
      const bytes = crypto.getRandomValues(new Uint8Array(16));
      const id = Array.from(bytes, byte => byte.toString(16).padStart(2, "0")).join("");
      await model.save([...model.tasks, { id, title: clean, done: false }]);
      navigate("/");
    } catch { setFailure("Could not save your task. Keep this page open and try again."); }
  }
  return <Frame>
    <h1>New task</h1>
    <form onSubmit={submit} noValidate>
      <label for="task-title">Task title</label>
      <input ref={input} id="task-title" name="title" value={title} maxLength={120} required aria-invalid={invalid} aria-describedby={invalid ? "title-help title-error" : "title-help"} onInput={event => { setTitle(event.currentTarget.value); setInvalid(false); }} />
      <p id="title-help">Use 1–120 characters.</p>
      {invalid && <p id="title-error" role="alert">Enter a task title.</p>}
      {model.phase === "loading" && <p role="status">Loading tasks…</p>}
      {model.phase === "error" && <p role="alert">{model.error} <Link href="/">Return to tasks to retry</Link>.</p>}
      {failure && <p role="alert">{failure}</p>}
      <button type="submit" disabled={model.phase !== "ready" || model.busy}>{model.busy ? "Saving…" : "Create task"}</button>
    </form>
  </Frame>;
}

function About() {
  return <Frame><h1>About this application</h1><p>Built with ordinary CSS, Preact components, and static files.</p><p>Tasks belong to this browser and origin. This starter has no sign-in, server database, backup, or multi-device sync. Do not use it for sensitive data.</p></Frame>;
}

export const routes = [
  { path: "/", component: Tasks },
  { path: "/new", component: NewTask },
  { path: "/about", component: About },
];

export default function App() {
  const [tasks, setTasks] = useState<Task[]>([]);
  const [phase, setPhase] = useState<"loading" | "ready" | "error">("loading");
  const [error, setError] = useState("");
  const [busy, setBusy] = useState(false);
  const revision = useRef(0);
  const saving = useRef(false);
  async function reload() {
    if (saving.current) return;
    const current = ++revision.current;
    setPhase("loading");
    setError("");
    try {
      const loaded = await storage.read();
      if (current !== revision.current) return;
      setTasks(loaded);
      setPhase("ready");
    } catch {
      if (current !== revision.current) return;
      setError("Could not read saved tasks. Check browser storage permissions or restore valid saved data, then retry. Existing data was not overwritten.");
      setPhase("error");
    }
  }
  useEffect(() => { void reload(); return () => { revision.current++; }; }, []);
  async function save(next: Task[]) {
    if (saving.current || phase !== "ready") throw new Error("Storage is not ready");
    saving.current = true;
    setBusy(true);
    try { await storage.write(next); setTasks(next); }
    finally { saving.current = false; setBusy(false); }
  }
  return <TasksContext.Provider value={{ tasks, phase, error, busy, reload: () => void reload(), save }}><Router base={spa.base} routes={routes} /></TasksContext.Provider>;
}
