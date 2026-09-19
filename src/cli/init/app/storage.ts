export interface Task { id: string; title: string; done: boolean }
export interface TaskStorage {
  read(): Promise<Task[]>;
  write(tasks: Task[]): Promise<void>;
}

const key = "zigapagos.tasks.v1";

// Browser-local example only. Replace this adapter for a shared backend.
// No browser globals are accessed during import or server rendering.
export const storage: TaskStorage = {
  async read() {
    const text = localStorage.getItem(key);
    if (text === null) return [];
    const value: unknown = JSON.parse(text);
    if (!Array.isArray(value) || value.some(task =>
      !task || typeof task.id !== "string" || typeof task.title !== "string" ||
      typeof task.done !== "boolean" || !task.title.trim() || task.title.length > 120
    ) || new Set(value.map(task => task.id)).size !== value.length) {
      throw new Error("Saved tasks have an unsupported format. No data was overwritten.");
    }
    return value;
  },
  async write(tasks) {
    localStorage.setItem(key, JSON.stringify(tasks));
  },
};
