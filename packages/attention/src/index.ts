import { Type, type Static } from "@sinclair/typebox";
import { Value } from "@sinclair/typebox/value";

import type { AttentionDecision, CueEvent } from "@wakeoncue/contracts";
import { canonicalJson, deterministicId, sha256, type EpisodeProjection } from "@wakeoncue/core";

export type SourceMode = "SHADOW" | "NOTIFY" | "WAKE";
export type AttentionDisposition =
  "NONE" | "OBSERVATION_REQUIRED" | "SHADOW_RECORDED" | "NOTIFICATION_QUEUED" | "WAKE_QUEUED";

interface ConversationSegment {
  text: string;
  speakerRef: string;
  isSubject: boolean;
  startSeconds: number;
  endSeconds: number;
}

export interface ConversationSignals {
  commitment?: string;
  deadline?: string;
  recipient?: string;
  ambiguousCommitment: boolean;
  promptInjectionDetected: boolean;
  retracted: boolean;
  subjectSegmentCount: number;
}

function readConversation(episode: EpisodeProjection): {
  segments: ConversationSegment[];
  actionItems: Array<{ description: string; completed: boolean; dueAt?: string }>;
} {
  const raw = episode.latestData["conversation"];
  if (typeof raw !== "object" || raw === null) return { actionItems: [], segments: [] };
  const record = raw as Record<string, unknown>;
  const segments = Array.isArray(record["segments"])
    ? record["segments"].filter(
        (segment): segment is ConversationSegment =>
          typeof segment === "object" &&
          segment !== null &&
          typeof (segment as Record<string, unknown>)["text"] === "string" &&
          typeof (segment as Record<string, unknown>)["speakerRef"] === "string" &&
          typeof (segment as Record<string, unknown>)["isSubject"] === "boolean" &&
          typeof (segment as Record<string, unknown>)["startSeconds"] === "number" &&
          typeof (segment as Record<string, unknown>)["endSeconds"] === "number",
      )
    : [];
  const actionItems = Array.isArray(record["actionItems"])
    ? record["actionItems"].flatMap((item) => {
        if (
          typeof item !== "object" ||
          item === null ||
          typeof (item as Record<string, unknown>)["description"] !== "string" ||
          typeof (item as Record<string, unknown>)["completed"] !== "boolean"
        ) {
          return [];
        }
        const dueAt = (item as Record<string, unknown>)["dueAt"];
        return [
          {
            description: (item as Record<string, unknown>)["description"] as string,
            completed: (item as Record<string, unknown>)["completed"] as boolean,
            ...(typeof dueAt === "string" ? { dueAt } : {}),
          },
        ];
      })
    : [];
  return { actionItems, segments };
}

function addUtcDays(date: string, days: number): string {
  const parsed = new Date(`${date}T00:00:00.000Z`);
  parsed.setUTCDate(parsed.getUTCDate() + days);
  return parsed.toISOString().slice(0, 10);
}

function nextWeekday(date: string, targetDay: number): string {
  const current = new Date(`${date}T00:00:00.000Z`).getUTCDay();
  const delta = (targetDay - current + 7) % 7 || 7;
  return addUtcDays(date, delta);
}

function extractDeadline(text: string, occurredAt: string): string | undefined {
  const date = occurredAt.slice(0, 10);
  const absolute = text.match(/(\d{1,2})月(\d{1,2})日?/u);
  if (absolute?.[1] && absolute[2]) {
    return `${date.slice(0, 4)}-${absolute[1].padStart(2, "0")}-${absolute[2].padStart(2, "0")}`;
  }
  if (/后天/u.test(text)) return addUtcDays(date, 2);
  if (/明天/u.test(text)) return addUtcDays(date, 1);
  if (/今天|今晚/u.test(text)) return date;
  const weekday = text.match(/周([一二三四五六日天])/u)?.[1];
  if (weekday) {
    const days: Record<string, number> = {
      一: 1,
      二: 2,
      三: 3,
      四: 4,
      五: 5,
      六: 6,
      日: 0,
      天: 0,
    };
    return nextWeekday(date, days[weekday] ?? 0);
  }
  return undefined;
}

function extractRecipient(text: string): string | undefined {
  return text.match(/(?:发给|发送给|交给|提交给|回复)([\p{Script=Han}A-Za-z0-9_-]{1,20})/u)?.[1];
}

const commitmentVerb = /(?:发|发送|提交|回复|交付|完成|整理|确认|提供|联系|跟进|处理)/u;
const weakOrHypothetical =
  /(?:也许|可能|有空|看看|如果|假如|假设|开玩笑|想不想|要不要|能不能|是否)/u;
const retraction = /(?:算了|不用了|取消|撤回|我不(?:发|做|提交|回复|处理)了)/u;
const promptInjection =
  /(?:忽略.{0,8}(?:指令|提示)|system prompt|prompt injection|绕过.{0,8}(?:审批|授权))/iu;

export function extractConversationSignals(episode: EpisodeProjection): ConversationSignals {
  const { segments, actionItems } = readConversation(episode);
  const subjectSegments = segments.filter((segment) => segment.isSubject);
  const subjectText = subjectSegments.map((segment) => segment.text).join("\n");
  const promptInjectionDetected = promptInjection.test(subjectText);
  const retracted = retraction.test(subjectText);
  const candidate = subjectSegments.find(
    (segment) =>
      /(?:我|本人)/u.test(segment.text) &&
      commitmentVerb.test(segment.text) &&
      !weakOrHypothetical.test(segment.text),
  );
  const actionItem = actionItems.find(
    (item) => !item.completed && !weakOrHypothetical.test(item.description),
  );
  const commitment = candidate?.text ?? actionItem?.description;
  const deadline = commitment
    ? (extractDeadline(commitment, episode.lastOccurredAt) ?? actionItem?.dueAt?.slice(0, 10))
    : undefined;
  const recipient = commitment ? extractRecipient(commitment) : undefined;
  const ambiguousCommitment =
    !commitment &&
    subjectSegments.some(
      (segment) => commitmentVerb.test(segment.text) && !weakOrHypothetical.test(segment.text),
    );
  return {
    ...(commitment ? { commitment } : {}),
    ...(deadline ? { deadline } : {}),
    ...(recipient ? { recipient } : {}),
    ambiguousCommitment,
    promptInjectionDetected,
    retracted,
    subjectSegmentCount: subjectSegments.length,
  };
}

export const StructuredJudgeOutputSchema = Type.Object(
  {
    verdict: Type.Union([
      Type.Literal("IGNORE"),
      Type.Literal("OBSERVE_MORE"),
      Type.Literal("WAKE_AGENT"),
    ]),
    reasonCodes: Type.Array(Type.String({ minLength: 1 }), { minItems: 1, maxItems: 8 }),
    scores: Type.Object(
      {
        relevance: Type.Number({ minimum: 0, maximum: 1 }),
        urgency: Type.Number({ minimum: 0, maximum: 1 }),
        novelty: Type.Number({ minimum: 0, maximum: 1 }),
        userCost: Type.Number({ minimum: 0, maximum: 1 }),
      },
      { additionalProperties: false },
    ),
  },
  { additionalProperties: false },
);

export type StructuredJudgeOutput = Static<typeof StructuredJudgeOutputSchema>;

export interface StructuredJudgeInput {
  signalVersion: "wakeoncue.signal/conversation-v1";
  commitment?: string;
  deadline?: string;
  recipient?: string;
  hasTrustedEvidence: boolean;
}

export interface StructuredJudge {
  readonly modelRef: string;
  judge(
    input: StructuredJudgeInput,
    budget: { timeoutMs: number; maxOutputTokens: number },
  ): Promise<unknown>;
}

export class DeterministicStructuredJudge implements StructuredJudge {
  readonly modelRef = "deterministic-structured-judge/v1";

  judge(input: StructuredJudgeInput): Promise<StructuredJudgeOutput> {
    if (!input.commitment || !input.hasTrustedEvidence) {
      return Promise.resolve({
        verdict: "IGNORE",
        reasonCodes: ["NO_EXPLICIT_COMMITMENT"],
        scores: { relevance: 0.2, urgency: 0.1, novelty: 0.5, userCost: 0.8 },
      });
    }
    if (!input.deadline) {
      return Promise.resolve({
        verdict: "OBSERVE_MORE",
        reasonCodes: ["COMMITMENT_DEADLINE_MISSING"],
        scores: { relevance: 0.8, urgency: 0.4, novelty: 0.8, userCost: 0.5 },
      });
    }
    return Promise.resolve({
      verdict: "WAKE_AGENT",
      reasonCodes: ["EXPLICIT_SUBJECT_COMMITMENT", "DEADLINE_PRESENT"],
      scores: { relevance: 0.95, urgency: 0.85, novelty: 0.9, userCost: 0.2 },
    });
  }
}

export interface JudgeRunResult {
  output: StructuredJudgeOutput;
  modelRef?: string;
  attempts: number;
  fallback: boolean;
}

export async function runStructuredJudge(
  judge: StructuredJudge,
  input: StructuredJudgeInput,
  options: { timeoutMs?: number; maxOutputTokens?: number } = {},
): Promise<JudgeRunResult> {
  const timeoutMs = options.timeoutMs ?? 4_000;
  const maxOutputTokens = options.maxOutputTokens ?? 256;
  for (let attempt = 1; attempt <= 2; attempt += 1) {
    try {
      const result = await Promise.race([
        judge.judge(input, { timeoutMs, maxOutputTokens }),
        new Promise<never>((_resolve, reject) =>
          setTimeout(() => reject(new Error("JUDGE_TIMEOUT")), timeoutMs),
        ),
      ]);
      if (Value.Check(StructuredJudgeOutputSchema, result)) {
        return { output: result, modelRef: judge.modelRef, attempts: attempt, fallback: false };
      }
    } catch {
      // Invalid, failed, and timed-out judges retry once, then fail closed below.
    }
  }
  return {
    output: {
      verdict: "IGNORE",
      reasonCodes: ["JUDGE_FAILED_SAFE"],
      scores: { relevance: 0, urgency: 0, novelty: 0, userCost: 1 },
    },
    attempts: 2,
    fallback: true,
  };
}

export interface ObservationRequest {
  capability: string;
  purpose: string;
  dataScope: string[];
  maxCost: number;
  ttlSeconds: number;
  retention: string;
}

export interface ObservationCapability {
  name: string;
  readOnly: true;
  allowedScopes: string[];
  maxCost: number;
  maxTtlSeconds: number;
}

export class ObservationBroker {
  private readonly capabilities = new Map<string, ObservationCapability>();

  register(capability: ObservationCapability): void {
    if (!capability.readOnly) throw new Error("OBSERVATION_CAPABILITY_MUST_BE_READ_ONLY");
    this.capabilities.set(capability.name, capability);
  }

  authorize(request: ObservationRequest): { authorized: true; expiresInSeconds: number } {
    const capability = this.capabilities.get(request.capability);
    if (!capability) throw new Error("OBSERVATION_CAPABILITY_NOT_REGISTERED");
    if (request.maxCost > capability.maxCost) throw new Error("OBSERVATION_COST_EXCEEDED");
    if (request.ttlSeconds > capability.maxTtlSeconds) throw new Error("OBSERVATION_TTL_EXCEEDED");
    if (request.dataScope.some((scope) => !capability.allowedScopes.includes(scope))) {
      throw new Error("OBSERVATION_SCOPE_EXCEEDED");
    }
    if (!/^P/u.test(request.retention)) throw new Error("OBSERVATION_RETENTION_REQUIRED");
    return { authorized: true, expiresInSeconds: request.ttlSeconds };
  }
}

export interface AttentionInput {
  episode: EpisodeProjection;
  events: CueEvent[];
  sourceId: string;
  cueType: string;
  mode: SourceMode;
  evaluationTime: string;
  timezoneOffsetMinutes: number;
  quietHours: { startHour: number; endHour: number };
  dailyBudget: {
    wakeLimit: number;
    notifyLimit: number;
    wakesUsed: number;
    notificationsUsed: number;
  };
  activeCooldownKeys: string[];
}

export interface AttentionEvaluation {
  decision: AttentionDecision;
  disposition: AttentionDisposition;
  mode: SourceMode;
  signals: ConversationSignals;
  judgeAttempts: number;
  judgeFallback: boolean;
  observationRequest?: ObservationRequest;
}

function localHour(timestamp: string, offsetMinutes: number): number {
  const date = new Date(timestamp);
  return new Date(date.getTime() + offsetMinutes * 60_000).getUTCHours();
}

function isQuietHour(hour: number, quiet: { startHour: number; endHour: number }): boolean {
  return quiet.startHour > quiet.endHour
    ? hour >= quiet.startHour || hour < quiet.endHour
    : hour >= quiet.startHour && hour < quiet.endHour;
}

function dispositionFor(
  verdict: AttentionDecision["decision"],
  mode: SourceMode,
): AttentionDisposition {
  if (verdict === "IGNORE") return "NONE";
  if (verdict === "OBSERVE_MORE") return "OBSERVATION_REQUIRED";
  if (mode === "SHADOW") return "SHADOW_RECORDED";
  if (mode === "NOTIFY") return "NOTIFICATION_QUEUED";
  return "WAKE_QUEUED";
}

export class AttentionEngine {
  readonly strategyVersion = "conversation-attention/v1";

  constructor(private readonly judge: StructuredJudge = new DeterministicStructuredJudge()) {}

  async decide(input: AttentionInput): Promise<AttentionEvaluation> {
    const signals = extractConversationSignals(input.episode);
    const evidenceRefs = input.episode.evidenceRefs;
    const event = input.events[0];
    const cooldownKey = `commitment:${sha256(
      canonicalJson({
        subject: input.episode.subject,
        commitment: signals.commitment,
        deadline: signals.deadline,
        recipient: signals.recipient,
      }),
    ).slice(0, 24)}`;
    let judgeResult: JudgeRunResult = {
      output: {
        verdict: "IGNORE",
        reasonCodes: ["HARD_GATE_REJECTED"],
        scores: { relevance: 0, urgency: 0, novelty: 0, userCost: 1 },
      },
      attempts: 0,
      fallback: false,
    };

    const privacyAllowed = event?.privacy.purpose.includes("attention") ?? false;
    const hardGateReason =
      !event || event.confidence < 0.65
        ? "CONFIDENCE_BELOW_THRESHOLD"
        : !privacyAllowed
          ? "PRIVACY_PURPOSE_NOT_ALLOWED"
          : input.episode.retracted || signals.retracted
            ? "COMMITMENT_RETRACTED"
            : signals.promptInjectionDetected
              ? "UNTRUSTED_PROMPT_INJECTION"
              : signals.subjectSegmentCount === 0
                ? "SUBJECT_SPEAKER_NOT_FOUND"
                : undefined;

    if (hardGateReason) {
      judgeResult.output.reasonCodes = [hardGateReason];
    } else if (
      isQuietHour(localHour(input.evaluationTime, input.timezoneOffsetMinutes), input.quietHours)
    ) {
      judgeResult.output.reasonCodes = ["QUIET_HOURS_ACTIVE"];
    } else if (
      input.mode === "WAKE" &&
      input.dailyBudget.wakesUsed >= input.dailyBudget.wakeLimit
    ) {
      judgeResult.output.reasonCodes = ["DAILY_WAKE_BUDGET_EXHAUSTED"];
    } else if (
      input.mode === "NOTIFY" &&
      input.dailyBudget.notificationsUsed >= input.dailyBudget.notifyLimit
    ) {
      judgeResult.output.reasonCodes = ["DAILY_NOTIFICATION_BUDGET_EXHAUSTED"];
    } else if (input.activeCooldownKeys.includes(cooldownKey)) {
      judgeResult.output.reasonCodes = ["SEMANTIC_COOLDOWN_ACTIVE"];
    } else {
      judgeResult = await runStructuredJudge(this.judge, {
        signalVersion: "wakeoncue.signal/conversation-v1",
        ...(signals.commitment ? { commitment: signals.commitment } : {}),
        ...(signals.deadline ? { deadline: signals.deadline } : {}),
        ...(signals.recipient ? { recipient: signals.recipient } : {}),
        hasTrustedEvidence: evidenceRefs.length > 0,
      });
    }

    const stateDigest = sha256(
      canonicalJson({
        episodeEventIds: input.episode.eventIds,
        mode: input.mode,
        evaluationDate: input.evaluationTime.slice(0, 10),
        budget: input.dailyBudget,
        cooldown: input.activeCooldownKeys,
        strategyVersion: this.strategyVersion,
      }),
    );
    const decision: AttentionDecision = {
      specVersion: "wakeoncue.decision/v1",
      decisionId: deterministicId("dec", `${input.episode.episodeId}:${stateDigest}`),
      episodeId: input.episode.episodeId,
      decision: judgeResult.output.verdict,
      reasonCodes: judgeResult.output.reasonCodes,
      scores: judgeResult.output.scores,
      evidenceRefs,
      strategyVersion: this.strategyVersion,
      ...(judgeResult.modelRef ? { modelRef: judgeResult.modelRef } : {}),
      cooldownKey,
      expiresAt: new Date(new Date(input.evaluationTime).getTime() + 60 * 60_000).toISOString(),
    };
    return {
      decision,
      disposition: dispositionFor(decision.decision, input.mode),
      mode: input.mode,
      signals,
      judgeAttempts: judgeResult.attempts,
      judgeFallback: judgeResult.fallback,
      ...(decision.decision === "OBSERVE_MORE"
        ? {
            observationRequest: {
              capability: "conversation.recent_segments",
              purpose: "resolve missing commitment context",
              dataScope: [`conversation:${input.episode.correlationId}:last-2m`],
              maxCost: 1,
              ttlSeconds: 120,
              retention: "PT5M",
            },
          }
        : {}),
    };
  }
}
