#!/usr/bin/env python3
"""Continuously send invalid UDP datagrams for an event-loop fairness test."""

import argparse
import json
import socket
import threading
import time


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--host", default="127.0.0.1")
    parser.add_argument("--port", type=int, required=True)
    parser.add_argument("--duration", type=float, default=2.0)
    parser.add_argument("--workers", type=int, default=8)
    args = parser.parse_args()

    if not 1 <= args.port <= 65535:
        parser.error("--port must be between 1 and 65535")
    if args.duration <= 0:
        parser.error("--duration must be positive")
    if args.workers <= 0:
        parser.error("--workers must be positive")

    family = socket.AF_INET6 if ":" in args.host else socket.AF_INET
    destination = (args.host, args.port)
    payload = b"not-a-ratelimitly-datagram".ljust(1024, b"x")
    barrier = threading.Barrier(args.workers + 1)
    start = threading.Event()
    counts = [0] * args.workers
    failures: list[str] = []

    def send_datagrams(index: int) -> None:
        try:
            with socket.socket(family, socket.SOCK_DGRAM) as sock:
                barrier.wait()
                start.wait()
                stop_at = time.monotonic() + args.duration
                while time.monotonic() < stop_at:
                    sock.sendto(payload, destination)
                    counts[index] += 1
        except (OSError, threading.BrokenBarrierError) as exc:
            failures.append(f"worker {index}: {exc}")
            barrier.abort()
            start.set()

    threads = [
        threading.Thread(target=send_datagrams, args=(index,), daemon=True)
        for index in range(args.workers)
    ]
    for thread in threads:
        thread.start()

    try:
        barrier.wait()
    except threading.BrokenBarrierError:
        start.set()
    else:
        print(
            json.dumps(
                {
                    "event": "ready",
                    "host": args.host,
                    "port": args.port,
                    "workers": args.workers,
                }
            ),
            flush=True,
        )
        start.set()

    for thread in threads:
        thread.join()

    sent = sum(counts)
    print(
        json.dumps({"event": "complete", "sent": sent, "failures": failures}),
        flush=True,
    )
    return 0 if not failures and sent > 0 else 1


if __name__ == "__main__":
    raise SystemExit(main())
