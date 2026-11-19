# The plan as OTLP JSON metrics for trunk2's `/v2/telemetry/v1/metrics`, sent when the
# token is a v2 API key. A name, unit, label value or bucket trunk2 does not list is
# rejected there with no error here, so this changes with its `dynamic-ci-metrics.ts`.

def text($key; $value): { key: $key, value: { stringValue: $value } };
def buckets($value; $bounds):
  ([$bounds | to_entries[] | select($value <= .value) | .key][0] // ($bounds | length)) as $bucket
  | [range(0; ($bounds | length) + 1) | if . == $bucket then "1" else "0" end];

({ "1": "success", "2": "failed", "3": "omitted" }[$status | tostring] // "unspecified") as $label
| [text("trunk.dynamic_ci.plan.status"; $label)] as $status_attribute
| ([$duration_ms, 0] | max) as $elapsed_ms
| "\($now_ms)000000" as $time
| "\($now_ms - $elapsed_ms)000000" as $start
| ($elapsed_ms / 1000) as $seconds
| def histogram($name; $unit; $value; $bounds):
    {
      name: $name,
      unit: $unit,
      histogram: {
        aggregationTemporality: 1,
        dataPoints: [{
          attributes: $status_attribute,
          startTimeUnixNano: $start,
          timeUnixNano: $time,
          count: "1",
          sum: $value,
          min: $value,
          max: $value,
          explicitBounds: $bounds,
          bucketCounts: buckets($value; $bounds)
        }]
      }
    };
{
  resourceMetrics: [{
    resource: {
      attributes: [
        text("service.name"; "trunk-dynamic-ci"),
        text("service.version"; $version),
        text("deployment.environment.name"; $environment)
      ]
    },
    scopeMetrics: [{
      scope: { name: "trunk-dynamic-ci", version: $version },
      metrics: (
        [{
          name: "trunk.dynamic_ci.plans",
          unit: "{plan}",
          sum: {
            aggregationTemporality: 1,
            isMonotonic: true,
            dataPoints: [{
              attributes: ($status_attribute + [text("trunk.dynamic_ci.plan.reason"; $reason)]),
              startTimeUnixNano: $start,
              timeUnixNano: $time,
              asInt: "1"
            }]
          }
        }]
        + (if $seconds <= 600
           then [histogram("trunk.dynamic_ci.plan.duration"; "s"; $seconds;
                  [0.05, 0.1, 0.25, 0.5, 1, 2.5, 5, 10, 30, 60, 120, 300, 600])]
           else [] end)
        + (if $job_count >= 0 and $job_count <= 256
           then [histogram("trunk.dynamic_ci.plan.jobs"; "{job}"; $job_count;
                  [0, 1, 2, 5, 10, 25, 50, 100, 250])]
           else [] end)
      )
    }]
  }]
}
