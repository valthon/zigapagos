import { createContext, useContext } from "@z/runtime";
import type { Task } from "./storage";

export interface TasksModel {
  tasks: Task[];
  phase: "loading" | "ready" | "error";
  error: string;
  busy: boolean;
  reload(): void;
  save(tasks: Task[]): Promise<void>;
}
export const TasksContext = createContext<TasksModel | null>(null);
export function useTasks(): TasksModel {
  const model = useContext(TasksContext);
  if (!model) throw new Error("Tasks must be rendered inside the application provider");
  return model;
}
