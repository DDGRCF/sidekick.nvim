import { writeFileSync } from "node:fs";

export default function (pi: any) {
  pi.registerFlag("sidekick-session-file", {
    description: "Internal Sidekick session tracking file",
    type: "string",
  });

  const persist = (_event: any, ctx: any) => {
    const path = pi.getFlag("sidekick-session-file") || process.env.SIDEKICK_OMP_SESSION_FILE;
    if (!path) return;
    writeFileSync(
      path,
      JSON.stringify({
        id: ctx.sessionManager.getSessionId(),
        file: ctx.sessionManager.getSessionFile(),
      }),
      "utf8",
    );
  };

  pi.on("session_start", persist);
  pi.on("session_switch", persist);
}
