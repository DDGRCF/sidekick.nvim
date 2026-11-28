import { appendFileSync, existsSync, mkdirSync, readFileSync, statSync, watchFile, writeFileSync } from "node:fs";
import { dirname } from "node:path";

function eventsFilePath(): string | undefined {
  if (process.env.SIDEKICK_PI_EVENTS_FILE) {
    return process.env.SIDEKICK_PI_EVENTS_FILE;
  }
  const sessionFile = process.env.SIDEKICK_PI_SESSION_FILE;
  if (!sessionFile) return undefined;
  if (sessionFile.endsWith(".json")) {
    return sessionFile.slice(0, -".json".length) + ".events.jsonl";
  }
  return sessionFile + ".events.jsonl";
}

function siblingControlPath(suffix: string): string | undefined {
  const sessionFile = process.env.SIDEKICK_PI_SESSION_FILE;
  if (!sessionFile) return undefined;
  if (sessionFile.endsWith(".json")) {
    return sessionFile.slice(0, -".json".length) + suffix;
  }
  return sessionFile + suffix;
}

function appendEvent(record: Record<string, unknown>): void {
  const path = eventsFilePath();
  if (!path) return;
  try {
    mkdirSync(dirname(path), { recursive: true });
    appendFileSync(path, JSON.stringify({ ts: Date.now(), ...record }) + "\n", "utf8");
  } catch {
    // Best-effort sideband telemetry: never disrupt interactive Pi execution.
  }
}

export default function (pi: any) {
  let activeModel = "";
  let cmdOffset = 0;

  const resolveModel = (msg?: any, ctx?: any): string => {
    const m = msg?.model || ctx?.model?.id || activeModel || "";
    if (typeof m === "string" && m) activeModel = m;
    return activeModel;
  };

  const writeStateSnapshot = (ctx?: any): void => {
    const statePath = siblingControlPath(".state.json");
    if (!statePath) return;
    try {
      mkdirSync(dirname(statePath), { recursive: true });
      const models = (ctx?.modelRegistry?.getAvailable?.() ?? []).map((m: any) => ({
        id: m?.provider && !String(m?.id || "").startsWith(`${m.provider}/`) ? `${m.provider}/${m.id}` : String(m?.id || ""),
        provider: String(m?.provider || ""),
        name: String(m?.name || m?.id || ""),
        reasoning: Boolean(m?.reasoning),
      }));
      const snap = {
        model: resolveModel(undefined, ctx),
        thinkingLevel: typeof pi.getThinkingLevel === "function" ? pi.getThinkingLevel() : "",
        availableModels: models,
      };
      writeFileSync(statePath, JSON.stringify(snap), "utf8");
    } catch {
      // Best-effort snapshot sync.
    }
  };

  const processCmdFile = (ctx?: any): void => {
    const cmdPath = siblingControlPath(".cmd.jsonl");
    if (!cmdPath || !existsSync(cmdPath)) return;
    try {
      const sz = statSync(cmdPath).size;
      if (sz <= cmdOffset) return;
      const raw = readFileSync(cmdPath, "utf8");
      const delta = raw.slice(cmdOffset);
      cmdOffset = raw.length;
      for (const line of delta.split("\n")) {
        const trimmed = line.trim();
        if (!trimmed) continue;
        try {
          const cmd = JSON.parse(trimmed);
          if (cmd.type === "set_thinking_level" && typeof cmd.level === "string" && typeof pi.setThinkingLevel === "function") {
            pi.setThinkingLevel(cmd.level);
          } else if (cmd.type === "set_model" && typeof cmd.model === "string" && typeof pi.setModel === "function") {
            const avail = ctx?.modelRegistry?.getAvailable?.() ?? [];
            const match = avail.find((m: any) => `${m.provider}/${m.id}` === cmd.model || m.id === cmd.model);
            if (match) {
              Promise.resolve(pi.setModel(match)).then(() => {
                if (typeof cmd.thinkingLevel === "string" && cmd.thinkingLevel && typeof pi.setThinkingLevel === "function") {
                  pi.setThinkingLevel(cmd.thinkingLevel);
                }
                writeStateSnapshot(ctx);
              }).catch(() => {});
            }
          }
        } catch {
          // Ignore malformed command line.
        }
      }
      writeStateSnapshot(ctx);
    } catch {
      // Ignore transient read errors.
    }
  };

  pi.on("session_start", (_event: any, ctx: any) => {
    const path = process.env.SIDEKICK_PI_SESSION_FILE;
    if (!path) return;
    const id = ctx?.sessionManager?.getSessionId?.();
    const file = ctx?.sessionManager?.getSessionFile?.();
    try {
      mkdirSync(dirname(path), { recursive: true });
      writeFileSync(path, JSON.stringify({ id, file }), "utf8");
    } catch {
      // Ignore write failures.
    }
    writeStateSnapshot(ctx);
    const cmdPath = siblingControlPath(".cmd.jsonl");
    if (cmdPath) {
      watchFile(cmdPath, { interval: 250 }, () => processCmdFile(ctx));
    }
    appendEvent({ type: "session_start", id, file, model: resolveModel(undefined, ctx) });
  });

  pi.on("agent_start", (_event: any, ctx: any) => {
    appendEvent({ type: "agent_start", model: resolveModel(undefined, ctx) });
  });

  pi.on("message_start", (event: any, ctx: any) => {
    const role = event?.message?.role ?? "";
    const model = resolveModel(event?.message, ctx);
    appendEvent({ type: "message_start", role, model });
  });

  pi.on("message_update", (event: any, ctx: any) => {
    const ame = event?.assistantMessageEvent;
    if (!ame || typeof ame.type !== "string") return;
    const model = resolveModel(event?.message, ctx);
    switch (ame.type) {
      case "text_start":
        appendEvent({ type: "text_start", contentIndex: ame.contentIndex ?? 0, model });
        break;
      case "text_delta":
        if (typeof ame.delta === "string" && ame.delta.length > 0) {
          appendEvent({ type: "text_delta", contentIndex: ame.contentIndex ?? 0, delta: ame.delta, model });
        }
        break;
      case "text_end":
        appendEvent({ type: "text_end", contentIndex: ame.contentIndex ?? 0, content: ame.content ?? "", model });
        break;
      case "thinking_start":
        appendEvent({ type: "thinking_start", contentIndex: ame.contentIndex ?? 0, model });
        break;
      case "thinking_delta":
        if (typeof ame.delta === "string" && ame.delta.length > 0) {
          appendEvent({ type: "thinking_delta", contentIndex: ame.contentIndex ?? 0, delta: ame.delta, model });
        }
        break;
      case "thinking_end":
        appendEvent({ type: "thinking_end", contentIndex: ame.contentIndex ?? 0, content: ame.content ?? "", model });
        break;
      case "toolcall_start":
        appendEvent({ type: "toolcall_start", id: ame.id ?? "", toolName: ame.toolName ?? "", model });
        break;
      case "toolcall_end":
        appendEvent({
          type: "toolcall_end",
          id: ame.toolCall?.id ?? "",
          toolName: ame.toolCall?.name ?? "",
          model,
        });
        break;
    }
  });

  pi.on("tool_execution_start", (event: any) => {
    appendEvent({
      type: "tool_execution_start",
      toolCallId: event?.toolCallId ?? "",
      toolName: event?.toolName ?? "",
    });
  });

  pi.on("tool_execution_end", (event: any) => {
    appendEvent({
      type: "tool_execution_end",
      toolCallId: event?.toolCallId ?? "",
      toolName: event?.toolName ?? "",
      isError: Boolean(event?.isError),
    });
  });

  pi.on("message_end", (event: any, ctx: any) => {
    const role = event?.message?.role ?? "";
    const model = resolveModel(event?.message, ctx);
    appendEvent({ type: "message_end", role, model });
  });

  pi.on("ui_prompt_start", (event: any) => {
    appendEvent({ type: "ui_prompt_start", kind: event?.kind ?? "" });
  });

  pi.on("ui_prompt_end", (event: any) => {
    appendEvent({ type: "ui_prompt_end", kind: event?.kind ?? "" });
  });

  pi.on("agent_end", (_event: any, ctx: any) => {
    appendEvent({ type: "agent_end", model: resolveModel(undefined, ctx) });
  });

  pi.on("agent_settled", (event: any, ctx: any) => {
    appendEvent({
      type: "agent_settled",
      aborted: Boolean(event?.aborted),
      model: resolveModel(undefined, ctx),
    });
  });
}
