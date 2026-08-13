import { Type, type Static, type TSchema } from "@sinclair/typebox";

const Id = (prefix: string) => Type.String({ pattern: `^${prefix}_[A-Za-z0-9_-]+$` });
const Timestamp = Type.String({
  pattern: "^\\d{4}-\\d{2}-\\d{2}T\\d{2}:\\d{2}:\\d{2}(?:\\.\\d+)?(?:Z|[+-]\\d{2}:\\d{2})$",
});
const EvidenceRefSchema = Type.Object(
  {
    uri: Type.String({ minLength: 1 }),
    mediaType: Type.String({ minLength: 1 }),
    classification: Type.Union([
      Type.Literal("public"),
      Type.Literal("internal"),
      Type.Literal("private"),
      Type.Literal("confidential"),
    ]),
  },
  { additionalProperties: false },
);

export const CueEventSchema = Type.Object(
  {
    specVersion: Type.Literal("wakeoncue.event/v1"),
    eventId: Id("evt"),
    type: Type.String({ minLength: 1 }),
    source: Type.Object(
      {
        adapter: Type.String({ minLength: 1 }),
        sourceId: Type.String({ minLength: 1 }),
        providerRef: Type.Optional(Type.String({ minLength: 1 })),
      },
      { additionalProperties: false },
    ),
    subject: Type.String({ minLength: 1 }),
    occurredAt: Timestamp,
    receivedAt: Timestamp,
    correlationId: Type.String({ minLength: 1 }),
    confidence: Type.Number({ minimum: 0, maximum: 1 }),
    data: Type.Record(Type.String(), Type.Unknown()),
    evidenceRefs: Type.Array(EvidenceRefSchema),
    privacy: Type.Object(
      {
        purpose: Type.Array(Type.String({ minLength: 1 }), { minItems: 1 }),
        retention: Type.String({ pattern: "^P" }),
      },
      { additionalProperties: false },
    ),
    idempotencyKey: Type.String({ minLength: 1, maxLength: 255 }),
  },
  { $id: "CueEventV1", additionalProperties: false },
);

export const AttentionDecisionSchema = Type.Object(
  {
    specVersion: Type.Literal("wakeoncue.decision/v1"),
    decisionId: Id("dec"),
    episodeId: Id("ep"),
    decision: Type.Union([
      Type.Literal("IGNORE"),
      Type.Literal("OBSERVE_MORE"),
      Type.Literal("WAKE_AGENT"),
    ]),
    reasonCodes: Type.Array(Type.String({ minLength: 1 }), { minItems: 1 }),
    scores: Type.Object(
      {
        relevance: Type.Number({ minimum: 0, maximum: 1 }),
        urgency: Type.Number({ minimum: 0, maximum: 1 }),
        novelty: Type.Number({ minimum: 0, maximum: 1 }),
        userCost: Type.Number({ minimum: 0, maximum: 1 }),
      },
      { additionalProperties: false },
    ),
    evidenceRefs: Type.Array(Type.String({ minLength: 1 }), { minItems: 1 }),
    strategyVersion: Type.String({ minLength: 1 }),
    modelRef: Type.Optional(Type.String({ minLength: 1 })),
    cooldownKey: Type.String({ minLength: 1 }),
    expiresAt: Timestamp,
  },
  { $id: "AttentionDecisionV1", additionalProperties: false },
);

export const TaskContractSchema = Type.Object(
  {
    contractVersion: Type.Literal("wakeoncue.task/v1"),
    taskId: Id("task"),
    subject: Type.String({ minLength: 1 }),
    goal: Type.String({ minLength: 1 }),
    successCriteria: Type.Array(Type.String({ minLength: 1 }), { minItems: 1 }),
    constraints: Type.Array(Type.String({ minLength: 1 })),
    contextRefs: Type.Array(Type.String({ minLength: 1 }), { minItems: 1 }),
    deadline: Type.Optional(Timestamp),
    runtime: Type.Object(
      {
        adapter: Type.String({ minLength: 1 }),
        profile: Type.String({ minLength: 1 }),
      },
      { additionalProperties: false },
    ),
    capabilityScope: Type.Array(Type.String({ minLength: 1 })),
    approvalRequiredFor: Type.Array(Type.String({ minLength: 1 })),
    idempotencyKey: Type.String({ minLength: 1, maxLength: 255 }),
  },
  { $id: "TaskContractV1", additionalProperties: false },
);

export const RuntimeCallbackSchema = Type.Object(
  {
    specVersion: Type.Literal("wakeoncue.runtime.callback/v1"),
    runtimeRunId: Id("run"),
    taskId: Id("task"),
    agentRunId: Type.String({ minLength: 1 }),
    status: Type.Union([
      Type.Literal("RUNNING"),
      Type.Literal("WAITING_APPROVAL"),
      Type.Literal("SUCCEEDED"),
      Type.Literal("FAILED"),
      Type.Literal("CANCELLED"),
      Type.Literal("UNKNOWN"),
      Type.Literal("RECONCILING"),
    ]),
    occurredAt: Timestamp,
    summary: Type.Optional(Type.String({ minLength: 1 })),
    evidenceRefs: Type.Array(Type.String({ minLength: 1 })),
  },
  { $id: "RuntimeCallbackV1", additionalProperties: false },
);

export const ToolAttemptSchema = Type.Object(
  {
    specVersion: Type.Literal("wakeoncue.attempt/v1"),
    attemptId: Id("attempt"),
    subject: Type.String({ minLength: 1 }),
    taskId: Id("task"),
    runtimeRunId: Id("run"),
    agentRunId: Type.String({ minLength: 1 }),
    toolCallId: Type.String({ minLength: 1 }),
    tool: Type.String({ minLength: 1 }),
    arguments: Type.Record(Type.String(), Type.Unknown()),
    argumentsDigest: Type.String({ pattern: "^sha256:[a-f0-9]{64}$" }),
    displaySummary: Type.String({ minLength: 1 }),
    risk: Type.Object(
      {
        sideEffect: Type.Union([
          Type.Literal("none"),
          Type.Literal("external-write"),
          Type.Literal("destructive"),
          Type.Literal("unknown"),
        ]),
        reversible: Type.Boolean(),
        dataClassification: Type.String({ minLength: 1 }),
        destination: Type.Optional(Type.String({ minLength: 1 })),
        estimatedCost: Type.Optional(Type.Number({ minimum: 0 })),
      },
      { additionalProperties: false },
    ),
    createdAt: Timestamp,
  },
  { $id: "ToolAttemptV1", additionalProperties: false },
);

export const RuntimeToolAttemptRequestSchema = Type.Object(
  {
    specVersion: Type.Literal("wakeoncue.runtime.tool-attempt/v1"),
    taskId: Id("task"),
    runtimeRunId: Id("run"),
    agentRunId: Type.String({ minLength: 1 }),
    toolCallId: Type.String({ minLength: 1 }),
    tool: Type.String({ minLength: 1 }),
    arguments: Type.Record(Type.String(), Type.Unknown()),
    priorAttemptId: Type.Optional(Id("attempt")),
  },
  { $id: "RuntimeToolAttemptRequestV1", additionalProperties: false },
);

export const RuntimeToolResultSchema = Type.Object(
  {
    specVersion: Type.Literal("wakeoncue.runtime.tool-result/v1"),
    attemptId: Id("attempt"),
    taskId: Id("task"),
    runtimeRunId: Id("run"),
    agentRunId: Type.String({ minLength: 1 }),
    toolCallId: Type.String({ minLength: 1 }),
    occurredAt: Timestamp,
    status: Type.Union([
      Type.Literal("SUCCEEDED"),
      Type.Literal("FAILED"),
      Type.Literal("UNKNOWN"),
    ]),
    resultDigest: Type.Optional(Type.String({ pattern: "^sha256:[a-f0-9]{64}$" })),
    errorCode: Type.Optional(Type.String({ minLength: 1 })),
    durationMs: Type.Optional(Type.Number({ minimum: 0 })),
  },
  { $id: "RuntimeToolResultV1", additionalProperties: false },
);

export const PermitSchema = Type.Object(
  {
    specVersion: Type.Literal("wakeoncue.permit/v1"),
    permitId: Id("permit"),
    subject: Type.String({ minLength: 1 }),
    runtimeRunId: Id("run"),
    taskId: Id("task"),
    attemptId: Id("attempt"),
    tool: Type.String({ minLength: 1 }),
    argumentsDigest: Type.String({ pattern: "^sha256:[a-f0-9]{64}$" }),
    issuedAt: Timestamp,
    expiresAt: Timestamp,
    consumedAt: Type.Optional(Timestamp),
  },
  { $id: "PermitV1", additionalProperties: false },
);

export const OutcomeSchema = Type.Object(
  {
    specVersion: Type.Literal("wakeoncue.outcome/v1"),
    outcomeId: Id("outcome"),
    taskId: Id("task"),
    runtimeRunId: Id("run"),
    status: Type.Union([
      Type.Literal("SUCCEEDED"),
      Type.Literal("FAILED"),
      Type.Literal("CANCELLED"),
      Type.Literal("UNKNOWN"),
    ]),
    verification: Type.Union([
      Type.Literal("reported"),
      Type.Literal("tool-confirmed"),
      Type.Literal("externally-verified"),
    ]),
    summary: Type.String({ minLength: 1 }),
    evidenceRefs: Type.Array(Type.String({ minLength: 1 })),
    occurredAt: Timestamp,
  },
  { $id: "OutcomeV1", additionalProperties: false },
);

export const NotificationSchema = Type.Object(
  {
    specVersion: Type.Literal("wakeoncue.notification/v1"),
    notificationId: Id("notification"),
    taskId: Id("task"),
    outcomeId: Type.Optional(Id("outcome")),
    channel: Type.String({ minLength: 1 }),
    category: Type.Union([
      Type.Literal("approval"),
      Type.Literal("high-risk-failure"),
      Type.Literal("verified-completion"),
      Type.Literal("summary"),
    ]),
    deduplicationKey: Type.String({ minLength: 1 }),
    payload: Type.Record(Type.String(), Type.Unknown()),
    createdAt: Timestamp,
  },
  { $id: "NotificationV1", additionalProperties: false },
);

export const ExternalOutcomeVerificationSchema = Type.Object(
  {
    specVersion: Type.Literal("wakeoncue.outcome.external-verification/v1"),
    taskId: Id("task"),
    runtimeRunId: Id("run"),
    status: Type.Union([
      Type.Literal("SUCCEEDED"),
      Type.Literal("FAILED"),
      Type.Literal("CANCELLED"),
      Type.Literal("UNKNOWN"),
    ]),
    summary: Type.String({ minLength: 1 }),
    evidenceRefs: Type.Array(Type.String({ minLength: 1 }), { minItems: 1 }),
    occurredAt: Timestamp,
    verifier: Type.String({ minLength: 1 }),
  },
  { $id: "ExternalOutcomeVerificationV1", additionalProperties: false },
);

export const NativeNotificationReceiptSchema = Type.Object(
  {
    specVersion: Type.Literal("wakeoncue.notification.native-receipt/v1"),
    receiptId: Type.String({ minLength: 1 }),
    taskId: Id("task"),
    outcomeId: Id("outcome"),
    runtimeRunId: Id("run"),
    channel: Type.String({ minLength: 1 }),
    status: Type.Union([
      Type.Literal("DELIVERED"),
      Type.Literal("FAILED"),
      Type.Literal("UNKNOWN"),
    ]),
    occurredAt: Timestamp,
  },
  { $id: "NativeNotificationReceiptV1", additionalProperties: false },
);

export const NotificationReceiptSchema = Type.Object(
  {
    specVersion: Type.Literal("wakeoncue.notification.receipt/v1"),
    notificationId: Id("notification"),
    status: Type.Union([
      Type.Literal("DELIVERED"),
      Type.Literal("FAILED"),
      Type.Literal("UNKNOWN"),
      Type.Literal("OPENED"),
      Type.Literal("ACKNOWLEDGED"),
      Type.Literal("DISMISSED"),
    ]),
    occurredAt: Timestamp,
    externalRef: Type.Optional(Type.String({ minLength: 1 })),
  },
  { $id: "NotificationReceiptV1", additionalProperties: false },
);

export const TaskFeedbackSchema = Type.Object(
  {
    specVersion: Type.Literal("wakeoncue.feedback/v1"),
    taskId: Id("task"),
    kind: Type.Union([
      Type.Literal("ACCEPTED"),
      Type.Literal("IGNORED"),
      Type.Literal("REJECTED"),
      Type.Literal("TOPIC_CLOSED"),
    ]),
    occurredAt: Timestamp,
  },
  { $id: "TaskFeedbackV1", additionalProperties: false },
);

export const schemaRegistry = {
  "wakeoncue.event/v1": CueEventSchema,
  "wakeoncue.decision/v1": AttentionDecisionSchema,
  "wakeoncue.task/v1": TaskContractSchema,
  "wakeoncue.runtime.callback/v1": RuntimeCallbackSchema,
  "wakeoncue.attempt/v1": ToolAttemptSchema,
  "wakeoncue.permit/v1": PermitSchema,
  "wakeoncue.outcome/v1": OutcomeSchema,
  "wakeoncue.notification/v1": NotificationSchema,
  "wakeoncue.outcome.external-verification/v1": ExternalOutcomeVerificationSchema,
  "wakeoncue.notification.native-receipt/v1": NativeNotificationReceiptSchema,
  "wakeoncue.notification.receipt/v1": NotificationReceiptSchema,
  "wakeoncue.feedback/v1": TaskFeedbackSchema,
} satisfies Record<string, TSchema>;

export type CueEvent = Static<typeof CueEventSchema>;
export type AttentionDecision = Static<typeof AttentionDecisionSchema>;
export type TaskContract = Static<typeof TaskContractSchema>;
export type RuntimeCallback = Static<typeof RuntimeCallbackSchema>;
export type ToolAttempt = Static<typeof ToolAttemptSchema>;
export type RuntimeToolAttemptRequest = Static<typeof RuntimeToolAttemptRequestSchema>;
export type RuntimeToolResult = Static<typeof RuntimeToolResultSchema>;
export type Permit = Static<typeof PermitSchema>;
export type Outcome = Static<typeof OutcomeSchema>;
export type Notification = Static<typeof NotificationSchema>;
export type ExternalOutcomeVerification = Static<typeof ExternalOutcomeVerificationSchema>;
export type NativeNotificationReceipt = Static<typeof NativeNotificationReceiptSchema>;
export type NotificationReceipt = Static<typeof NotificationReceiptSchema>;
export type TaskFeedback = Static<typeof TaskFeedbackSchema>;
