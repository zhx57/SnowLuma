#!/usr/bin/env python3
import argparse
import asyncio
import json
import sys
import uuid
from typing import Any, Dict

try:
    import websockets
except ImportError:
    print("Missing dependency: websockets")
    print("Install with: pip install websockets")
    sys.exit(2)


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="OneBot WS API smoke test")
    parser.add_argument("--url", default="ws://127.0.0.1:3001/", help="OneBot WebSocket URL")
    parser.add_argument("--token", default="", help="Bearer token if OneBot accessToken is set")
    parser.add_argument("--group-id", type=int, default=1081372778, help="Target group_id for send_group_msg")
    parser.add_argument("--message", default="hello from snowluma from refactor", help="Message text to send")
    parser.add_argument("--timeout", type=float, default=20.0, help="Per-request timeout seconds")
    return parser.parse_args()


async def recv_json(ws: Any, timeout: float) -> Dict[str, Any]:
    raw = await asyncio.wait_for(ws.recv(), timeout)
    if isinstance(raw, bytes):
        raw = raw.decode("utf-8", errors="replace")
    return json.loads(raw)


async def call_api(ws: Any, action: str, params: Dict[str, Any], timeout: float) -> Dict[str, Any]:
    echo = f"py-{action}-{uuid.uuid4().hex[:8]}"
    payload = {
        "action": action,
        "params": params,
        "echo": echo,
    }
    await ws.send(json.dumps(payload, ensure_ascii=False))

    while True:
        resp = await recv_json(ws, timeout)
        if resp.get("echo") == echo:
            return resp


def short_json(data: Dict[str, Any], max_len: int = 240) -> str:
    text = json.dumps(data, ensure_ascii=False)
    if len(text) <= max_len:
        return text
    return text[:max_len] + "..."


async def main() -> int:
    args = parse_args()

    headers = {}
    if args.token:
        headers["Authorization"] = f"Bearer {args.token}"

    try:
        async with websockets.connect(args.url, additional_headers=headers, max_size=20 * 1024 * 1024) as ws:
            try:
                first = await recv_json(ws, 1.0)
                print("[WS] first event:", short_json(first))
            except Exception:
                pass

            status = await call_api(ws, "get_status", {}, args.timeout)
            print("[API] get_status:", short_json(status))

            groups = await call_api(ws, "get_group_list", {}, args.timeout)
            group_count = len(groups.get("data", [])) if isinstance(groups.get("data"), list) else -1
            print(f"[API] get_group_list: group_count={group_count}")

            send_resp = await call_api(
                ws,
                "send_group_msg",
                {
                    "group_id": args.group_id,
                    "message": args.message,
                },
                args.timeout,
            )
            print("[API] send_group_msg:", short_json(send_resp))

            ok = (
                status.get("status") == "ok"
                and groups.get("status") == "ok"
                and send_resp.get("status") == "ok"
            )
            return 0 if ok else 1
    except Exception as e:
        print("[ERROR]", str(e))
        return 1


if __name__ == "__main__":
    raise SystemExit(asyncio.run(main()))
