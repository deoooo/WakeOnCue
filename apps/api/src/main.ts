import { buildServer } from "./server.ts";

const server = await buildServer();
const host = process.env["WAKEONCUE_HOST"] ?? "127.0.0.1";
const port = Number(process.env["WAKEONCUE_API_PORT"] ?? "4310");

const shutdown = async (signal: string): Promise<void> => {
  server.log.info({ signal }, "graceful shutdown requested");
  await server.close();
};

process.once("SIGINT", () => void shutdown("SIGINT"));
process.once("SIGTERM", () => void shutdown("SIGTERM"));

await server.listen({ host, port });
