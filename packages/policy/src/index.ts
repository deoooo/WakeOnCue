import type { TaskContract, ToolAttempt } from "@wakeoncue/contracts";
import { canonicalJson, sha256 } from "@wakeoncue/core";

export type AuthorizationDecision = "ALLOW" | "APPROVE_ONCE" | "DENY";

export interface AuthorizationEvaluation {
  decision: AuthorizationDecision;
  reasonCode: string;
  capability: string;
  displaySummary: string;
  risk: ToolAttempt["risk"];
}

const safeReadTools = new Map<string, string>([
  ["read", "evidence.read"],
  ["memory_get", "evidence.read"],
  ["memory_search", "memory.search"],
  ["web_fetch", "web.read"],
  ["web_search", "web.search"],
]);

const approvalTools = new Map<string, string>([
  ["calendar.create", "calendar.write"],
  ["calendar.update", "calendar.write"],
  ["email.send", "external.send"],
  ["email_send", "external.send"],
  ["file.send", "external.send"],
  ["file_send", "external.send"],
  ["file.share", "external.send"],
  ["message.send", "external.send"],
  ["message_send", "external.send"],
  ["record.create", "external.write"],
  ["record.update", "external.write"],
  ["task.complete", "task.write"],
  ["task.create", "task.write"],
  ["task.update", "task.write"],
]);

const secretKey = /(?:authorization|cookie|credential|password|secret|token|api[_-]?key)/iu;
const destinationKeys = ["recipient", "recipients", "to", "destination", "contact", "channel"];

function redact(value: unknown, key = ""): unknown {
  if (secretKey.test(key)) return "<redacted>";
  if (Array.isArray(value)) return value.map((entry) => redact(entry));
  if (value !== null && typeof value === "object") {
    return Object.fromEntries(
      Object.entries(value as Record<string, unknown>).map(([entryKey, entry]) => [
        entryKey,
        redact(entry, entryKey),
      ]),
    );
  }
  return value;
}

export function redactToolArguments(
  argumentsValue: Record<string, unknown>,
): Record<string, unknown> {
  return redact(argumentsValue) as Record<string, unknown>;
}

function destination(argumentsValue: Record<string, unknown>): string | undefined {
  for (const key of destinationKeys) {
    const value = argumentsValue[key];
    if (typeof value === "string" && value.trim()) return `${key}:${value.trim()}`;
    if (Array.isArray(value) && value.every((entry) => typeof entry === "string")) {
      return `${key}:${value.join(",")}`;
    }
  }
  return undefined;
}

function summary(tool: string, argumentsValue: Record<string, unknown>): string {
  const serialized = canonicalJson(redactToolArguments(argumentsValue));
  return `${tool} ${serialized.length > 600 ? `${serialized.slice(0, 600)}…` : serialized}`;
}

export function argumentsDigest(argumentsValue: Record<string, unknown>): string {
  return `sha256:${sha256(canonicalJson(argumentsValue))}`;
}

export function evaluateAuthorization(
  contract: TaskContract,
  tool: string,
  argumentsValue: Record<string, unknown>,
): AuthorizationEvaluation {
  const normalizedTool = tool.trim().toLowerCase();
  const displaySummary = summary(tool, argumentsValue);
  const destinationValue = destination(argumentsValue);
  const readCapability = safeReadTools.get(normalizedTool);
  if (readCapability) {
    const capabilityInScope = contract.capabilityScope.includes(readCapability);
    const target =
      typeof argumentsValue["path"] === "string"
        ? argumentsValue["path"]
        : typeof argumentsValue["file_path"] === "string"
          ? argumentsValue["file_path"]
          : typeof argumentsValue["url"] === "string"
            ? argumentsValue["url"]
            : undefined;
    const targetInScope =
      normalizedTool === "read" || normalizedTool === "memory_get"
        ? typeof target === "string" && contract.contextRefs.includes(target)
        : normalizedTool === "web_fetch"
          ? typeof target === "string" && contract.contextRefs.includes(target)
          : true;
    const inScope = capabilityInScope && targetInScope;
    return {
      decision: inScope ? "ALLOW" : "DENY",
      reasonCode: inScope
        ? "BOUNDED_READ_ALLOWED"
        : capabilityInScope
          ? "READ_TARGET_OUT_OF_SCOPE"
          : "CAPABILITY_OUT_OF_SCOPE",
      capability: readCapability,
      displaySummary,
      risk: {
        sideEffect: "none",
        reversible: true,
        dataClassification: "private",
      },
    };
  }

  if (
    /(?:^|[._-])(?:delete|remove|destroy|payment|purchase|buy|lock|unlock)(?:$|[._-])/u.test(
      normalizedTool,
    ) ||
    normalizedTool.includes("device.control")
  ) {
    return {
      decision: "DENY",
      reasonCode: "MVP_FORBIDDEN_OPERATION",
      capability: "forbidden",
      displaySummary,
      risk: {
        sideEffect: "destructive",
        reversible: false,
        dataClassification: "confidential",
        ...(destinationValue ? { destination: destinationValue } : {}),
      },
    };
  }

  const approvalCapability = approvalTools.get(normalizedTool);
  if (approvalCapability) {
    const approvalInScope = contract.approvalRequiredFor.includes(approvalCapability);
    return {
      decision: approvalInScope ? "APPROVE_ONCE" : "DENY",
      reasonCode: approvalInScope ? "EXTERNAL_WRITE_REQUIRES_APPROVAL" : "CAPABILITY_OUT_OF_SCOPE",
      capability: approvalCapability,
      displaySummary,
      risk: {
        sideEffect: "external-write",
        reversible: false,
        dataClassification: "confidential",
        ...(destinationValue ? { destination: destinationValue } : {}),
      },
    };
  }

  return {
    decision: "DENY",
    reasonCode: "UNKNOWN_TOOL_DENIED",
    capability: "unknown",
    displaySummary,
    risk: {
      sideEffect: "unknown",
      reversible: false,
      dataClassification: "confidential",
      ...(destinationValue ? { destination: destinationValue } : {}),
    },
  };
}
