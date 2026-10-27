"""Dump every Telegram gift currently listed for resale on the Telegram gift market.

Uses the official MTProto API (payments.getStarGifts + payments.getResaleStarGifts)
through Telethon, logged in as a regular user account.

    pip install telethon
    export TG_API_ID=12345 TG_API_HASH=abcdef...   # from https://my.telegram.org
    python market_parser.py                        # -> market_gifts.json
    python market_parser.py --csv --send-to me     # CSV + send file to Saved Messages
    python market_parser.py --only "Plush Pepe" --only "Durov's Cap"
"""

import argparse
import asyncio
import csv
import json
import os
import sys
from datetime import datetime, timezone

from telethon import TelegramClient
from telethon.tl.functions.payments import GetResaleStarGiftsRequest, GetStarGiftsRequest
from telethon.tl.types import (
    StarGiftAttributeBackdrop,
    StarGiftAttributeModel,
    StarGiftAttributePattern,
    StarGiftUnique,
    StarsTonAmount,
)

PAGE_LIMIT = 100
PAGE_DELAY = 0.3  # seconds between requests, keeps us clear of FLOOD_WAIT


def rarity(attr):
    permille = getattr(attr.rarity, "permille", None)
    return f"{permille / 10:g}%" if permille is not None else type(attr.rarity).__name__


def peer_id(peer):
    if peer is None:
        return None
    return getattr(peer, "user_id", None) or getattr(peer, "channel_id", None) or getattr(peer, "chat_id", None)


def parse_unique(gift: StarGiftUnique, collection: str) -> dict:
    row = {
        "collection": collection,
        "title": gift.title,
        "num": gift.num,
        "slug": gift.slug,
        "link": f"https://t.me/nft/{gift.slug}",
        "price_stars": None,
        "price_ton": None,
        "ton_only": bool(gift.resale_ton_only),
        "model": None,
        "model_rarity": None,
        "backdrop": None,
        "backdrop_rarity": None,
        "pattern": None,
        "pattern_rarity": None,
        "owner_name": gift.owner_name,
        "owner_id": peer_id(gift.owner_id),
        "issued": gift.availability_issued,
        "total": gift.availability_total,
    }
    for amount in gift.resell_amount or []:
        if isinstance(amount, StarsTonAmount):
            row["price_ton"] = amount.amount / 1e9  # nanotons
        else:
            row["price_stars"] = amount.amount
    for attr in gift.attributes:
        for cls, key in ((StarGiftAttributeModel, "model"),
                         (StarGiftAttributeBackdrop, "backdrop"),
                         (StarGiftAttributePattern, "pattern")):
            if isinstance(attr, cls):
                row[key] = attr.name
                row[f"{key}_rarity"] = rarity(attr)
    return row


async def fetch_collection(client, gift_id: int, name: str) -> list[dict]:
    rows, offset = [], ""
    while True:
        res = await client(GetResaleStarGiftsRequest(
            gift_id=gift_id, offset=offset, limit=PAGE_LIMIT, sort_by_price=True))
        rows += [parse_unique(g, name) for g in res.gifts if isinstance(g, StarGiftUnique)]
        print(f"  {name}: {len(rows)}/{res.count}", end="\r", file=sys.stderr)
        if not res.next_offset or not res.gifts:
            break
        offset = res.next_offset
        await asyncio.sleep(PAGE_DELAY)
    print(file=sys.stderr)
    return rows


async def run(args):
    client = TelegramClient(args.session, int(os.environ["TG_API_ID"]), os.environ["TG_API_HASH"])
    await client.start()

    catalog = await client(GetStarGiftsRequest(hash=0))
    collections = [g for g in catalog.gifts if getattr(g, "availability_resale", None)]
    if args.only:
        wanted = {o.lower() for o in args.only}
        collections = [g for g in collections if (g.title or "").lower() in wanted]
    print(f"Collections on the market: {len(collections)}", file=sys.stderr)

    rows = []
    for g in collections:
        rows += await fetch_collection(client, g.id, g.title or str(g.id))
        await asyncio.sleep(PAGE_DELAY)

    out = args.out or f"market_gifts.{'csv' if args.csv else 'json'}"
    if args.csv:
        with open(out, "w", newline="", encoding="utf-8") as f:
            writer = csv.DictWriter(f, fieldnames=list(rows[0]) if rows else ["collection"])
            writer.writeheader()
            writer.writerows(rows)
    else:
        with open(out, "w", encoding="utf-8") as f:
            json.dump({"fetched_at": datetime.now(timezone.utc).isoformat(),
                       "count": len(rows), "gifts": rows}, f, ensure_ascii=False, indent=2)
    print(f"Saved {len(rows)} listings from {len(collections)} collections -> {out}", file=sys.stderr)

    if args.send_to:
        target = int(args.send_to) if args.send_to.lstrip("-").isdigit() else args.send_to
        await client.send_file(target, out,
                               caption=f"🎁 {len(rows)} gifts on the market ({len(collections)} collections)")
        print(f"Sent to {args.send_to}", file=sys.stderr)

    await client.disconnect()


def main():
    p = argparse.ArgumentParser(description="Dump all gifts listed on the Telegram gift market")
    p.add_argument("--out", help="output file (default market_gifts.json / .csv)")
    p.add_argument("--csv", action="store_true", help="write CSV instead of JSON")
    p.add_argument("--only", action="append", help="collection title to fetch (repeatable)")
    p.add_argument("--send-to", help="chat to send the dump to, e.g. me, @username or a chat id")
    p.add_argument("--session", default="gift_market", help="Telethon session file name")
    asyncio.run(run(p.parse_args()))


if __name__ == "__main__":
    main()
