import { afterEach, beforeEach, describe, expect, it } from "vitest";

import { buildServer } from "./server.ts";

describe("API bootstrap", () => {
  beforeEach(() => {
    process.env["WAKEONCUE_DATABASE_PATH"] = ":memory:";
  });

  afterEach(() => {
    delete process.env["WAKEONCUE_DATABASE_PATH"];
  });

  it("reports health and migration readiness", async () => {
    const server = await buildServer();
    try {
      const health = await server.inject({ method: "GET", url: "/health" });
      expect(health.statusCode).toBe(200);
      expect(health.json()).toMatchObject({ status: "ok", service: "wakeoncue-api" });
      const ready = await server.inject({ method: "GET", url: "/ready" });
      expect(ready.statusCode).toBe(200);
      expect(ready.json()).toMatchObject({ status: "ready", database: "ready" });
      const schemas = await server.inject({ method: "GET", url: "/v1/schemas" });
      expect(schemas.statusCode).toBe(200);
      expect(schemas.json<{ versions: string[] }>().versions).toEqual(
        expect.arrayContaining([
          "wakeoncue.event/v1",
          "wakeoncue.decision/v1",
          "wakeoncue.task/v1",
          "wakeoncue.attempt/v1",
          "wakeoncue.permit/v1",
          "wakeoncue.outcome/v1",
          "wakeoncue.notification/v1",
        ]),
      );
    } finally {
      await server.close();
    }
  });
});
