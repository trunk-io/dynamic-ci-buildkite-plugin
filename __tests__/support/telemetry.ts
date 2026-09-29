import protobuf from "protobufjs";

// A copy of trunk1's `services/telemetry/proto/v1/dynamic_ci.proto`, so the
// hand-written encoder in `lib/telemetry.jq` is checked against a real decoder.
const Repo = new protobuf.Type("Repo")
  .add(new protobuf.Field("host", 1, "string"))
  .add(new protobuf.Field("owner", 2, "string"))
  .add(new protobuf.Field("name", 3, "string"));
const Duration = new protobuf.Type("Duration")
  .add(new protobuf.Field("seconds", 1, "int64"))
  .add(new protobuf.Field("nanos", 2, "int32"));
const PlanRequestMetrics = new protobuf.Type("PlanRequestMetrics")
  .add(new protobuf.Field("action_version", 1, "string"))
  .add(new protobuf.Field("repo", 2, "Repo"))
  .add(new protobuf.Field("status", 3, "int32"))
  .add(new protobuf.Field("reason", 4, "string"))
  .add(new protobuf.Field("attempts", 5, "uint32"))
  .add(new protobuf.Field("duration", 6, "Duration"))
  .add(new protobuf.Field("job_count", 7, "uint32"));
new protobuf.Root().add(Repo).add(Duration).add(PlanRequestMetrics);

export interface DecodedTelemetry {
  actionVersion: string;
  repo: { host?: string; owner?: string; name?: string };
  status: number;
  reason: string;
  durationMs: number;
  jobCount: number;
}

export const decodeTelemetry = (payload: Buffer): DecodedTelemetry => {
  const decoded = PlanRequestMetrics.toObject(
    PlanRequestMetrics.decode(payload),
    { longs: Number, defaults: true },
  ) as {
    action_version: string;
    repo?: DecodedTelemetry["repo"];
    status: number;
    reason: string;
    duration?: { seconds: number; nanos: number };
    job_count: number;
  };
  return {
    actionVersion: decoded.action_version,
    repo: decoded.repo ?? {},
    status: decoded.status,
    reason: decoded.reason,
    durationMs:
      (decoded.duration?.seconds ?? 0) * 1000 +
      (decoded.duration?.nanos ?? 0) / 1_000_000,
    jobCount: decoded.job_count,
  };
};
