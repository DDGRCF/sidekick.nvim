import { writeFileSync } from "node:fs";

export default function (pi: any) {
  pi.on("session_start", (_event: any, ctx: any) => {
    const path = process.env.SIDEKICK_PI_SESSION_FILE;
    if (!path) return;
    writeFileSync(
      path,
      JSON.stringify({
        id: ctx.sessionManager.getSessionId(),
        file: ctx.sessionManager.getSessionFile(),
      }),
      "utf8",
    );
  });
}
