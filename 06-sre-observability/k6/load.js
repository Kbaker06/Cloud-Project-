// Steady, realistic-ish traffic so the SLIs have something to measure.
//   docker compose run --rm k6            (runs until you stop it, default 30m)
import http from "k6/http";
import { check, sleep } from "k6";

const targets = ["http://api-1:8080", "http://api-2:8080"];

export const options = {
  scenarios: {
    steady: {
      executor: "constant-arrival-rate",
      rate: Number(__ENV.RPS || 40),
      timeUnit: "1s",
      duration: __ENV.DURATION || "30m",
      preAllocatedVUs: 20,
      maxVUs: 200,
    },
  },
  // k6's own view of the SLO. Compare it with what Prometheus says.
  thresholds: {
    http_req_failed: ["rate<0.001"],
    "http_req_duration{kind:api}": ["p(99)<300"],
  },
};

export default function () {
  // A crude load balancer: a dead replica shows up as client errors, like a real LB without health checks.
  const base = targets[Math.floor(Math.random() * targets.length)];
  const roll = Math.random();
  let res;
  if (roll < 0.6) {
    res = http.get(`${base}/api/v1/notes`, { tags: { kind: "api" } });
  } else if (roll < 0.9) {
    res = http.post(`${base}/api/v1/notes`, JSON.stringify({ text: `note ${__ITER}` }), {
      headers: { "Content-Type": "application/json" },
      tags: { kind: "api" },
    });
  } else {
    res = http.get(`${base}/api/v1/work?ms=20`, { tags: { kind: "cpu" } });
  }
  check(res, { "not 5xx": (r) => r.status < 500 });
  sleep(0.1);
}
