#!/usr/bin/env python3
"""Fire orders at the deployed API — including retries and high-value orders — to exercise the pipeline.

python3 scripts/send_orders.py --url "$(terraform -chdir=terraform output -raw api_url)" -n 200 -c 20
python3 scripts/send_orders.py --poison 5 --queue-url "$(terraform -chdir=terraform output -raw queue_url)"
"""

from __future__ import annotations

import argparse
import collections
import json
import random
import time
import urllib.error
import urllib.request
import uuid
from concurrent.futures import ThreadPoolExecutor


def post_order(url: str, key: str) -> int:
    big = random.random() < 0.1
    body = {
        "customer_id": f"cust-{random.randint(1, 50)}",
        "items": [{"sku": "GPU" if big else "WIDGET", "qty": random.randint(1, 3), "unit_price": "1499.00" if big else "9.99"}],
    }
    req = urllib.request.Request(
        url.rstrip("/") + "/orders",
        data=json.dumps(body).encode(),
        headers={"Content-Type": "application/json", "Idempotency-Key": key},
        method="POST",
    )
    try:
        with urllib.request.urlopen(req, timeout=10) as resp:
            return resp.status
    except urllib.error.HTTPError as e:
        return e.code


def main() -> None:
    p = argparse.ArgumentParser()
    p.add_argument("--url")
    p.add_argument("-n", type=int, default=100, help="orders to send")
    p.add_argument("-c", type=int, default=10, help="concurrency")
    p.add_argument("--retry-rate", type=float, default=0.2, help="fraction of orders re-POSTed with the same key")
    p.add_argument("--poison", type=int, default=0, help="malformed messages to inject straight into SQS")
    p.add_argument("--queue-url")
    args = p.parse_args()

    if args.poison:
        import boto3  # only needed for this mode

        sqs = boto3.client("sqs")
        for i in range(args.poison):
            sqs.send_message(QueueUrl=args.queue_url, MessageBody=f'{{"broken": {i}')
        print(f"injected {args.poison} poison messages; watch them land in the DLQ after 3 receives")
        return

    keys = [uuid.uuid4().hex for _ in range(args.n)]
    keys += random.sample(keys, int(len(keys) * args.retry_rate))  # simulated client retries
    random.shuffle(keys)

    start = time.time()
    with ThreadPoolExecutor(max_workers=args.c) as pool:
        codes = collections.Counter(pool.map(lambda k: post_order(args.url, k), keys))
    elapsed = time.time() - start
    print(f"sent {len(keys)} requests ({args.n} unique orders) in {elapsed:.1f}s: {dict(codes)}")
    print("Now check: the table should contain exactly", args.n, "orders.")


if __name__ == "__main__":
    main()
