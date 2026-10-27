"""Watch the Telegram gift market and post every NEW listing under a price cap to a chat.

Everything already listed when the script starts is remembered and skipped; only gifts
put up for sale after launch are posted. Prices (Stars / TON) are converted to RUB with
the live TON rate from CoinGecko; Stars go through a fixed USD-per-star rate.

    export TG_API_ID=12345 TG_API_HASH=abcdef...
    python market_watch.py --chat @my_channel                 # cap 15 000 RUB
    python market_watch.py --chat -1001234567890 --max-rub 5000 --interval 20
"""

import argparse
import asyncio
import html
import json
import os
import sys
import time
import urllib.request

from telethon import TelegramClient
from telethon.tl.functions.payments import GetResaleStarGiftsRequest, GetStarGiftsRequest
from telethon.tl.types import StarGiftUnique

from market_parser import parse_unique

PAGE_LIMIT = 50          # newest listings checked per collection each round
REQUEST_DELAY = 0.35     # seconds between API calls
CATALOG_REFRESH = 30 * 60
RATES_REFRESH = 10 * 60
RATES_URL = "https://api.coingecko.com/api/v3/simple/price?ids=the-open-network&vs_currencies=usd,rub"


def log(*a):
    print(time.strftime("%H:%M:%S"), *a, file=sys.stderr, flush=True)


class Rates:
    """TON->RUB from CoinGecko, USD->RUB derived from the same quote."""

    def __init__(self, star_usd: float):
        self.star_usd = star_usd
        self.ton_rub = self.usd_rub = None
        self.updated = 0.0

    def refresh(self):
        if time.time() - self.updated < RATES_REFRESH and self.ton_rub:
            return
        try:
            with urllib.request.urlopen(RATES_URL, timeout=15) as r:
                q = json.load(r)["the-open-network"]
            self.ton_rub, self.usd_rub = q["rub"], q["rub"] / q["usd"]
            self.updated = time.time()
            log(f"rates: 1 TON = {self.ton_rub:.0f} RUB, 1 USD = {self.usd_rub:.2f} RUB, "
                f"1 Star = {self.star_usd * self.usd_rub:.2f} RUB")
        except Exception as e:  # keep the previous rates if the refresh fails
            log(f"rates refresh failed: {e}")

    def to_rub(self, row: dict):
        """Cheapest way to pay for the listing, in RUB (None if rates are unknown)."""
        if not self.ton_rub:
            return None
        options = []
        if row["price_ton"] is not None:
            options.append(row["price_ton"] * self.ton_rub)
        if row["price_stars"] is not None and not row["ton_only"]:
            options.append(row["price_stars"] * self.star_usd * self.usd_rub)
        return min(options) if options else None


def format_message(row: dict, rub: float) -> str:
    e = html.escape
    lines = [f'🎁 <b>{e(row["title"])} #{row["num"]}</b>', row["link"], ""]
    price = []
    if row["price_stars"] is not None and not row["ton_only"]:
        price.append(f'{row["price_stars"]:,} ⭐'.replace(",", " "))
    if row["price_ton"] is not None:
        price.append(f'{row["price_ton"]:g} TON')
    lines.append(f'💰 {" / ".join(price)} ≈ <b>{rub:,.0f} ₽</b>'.replace(",", " "))
    for key, label in (("model", "Модель"), ("backdrop", "Фон"), ("pattern", "Узор")):
        if row[key]:
            lines.append(f'{label}: {e(row[key])} ({row[f"{key}_rarity"]})')
    return "\n".join(lines)


async def newest(client, gift_id: int):
    # No sort flags = sorted by listing date, newest first.
    res = await client(GetResaleStarGiftsRequest(gift_id=gift_id, offset="", limit=PAGE_LIMIT))
    return [g for g in res.gifts if isinstance(g, StarGiftUnique)]


async def run(args):
    client = TelegramClient(args.session, int(os.environ["TG_API_ID"]), os.environ["TG_API_HASH"])
    client.flood_sleep_threshold = 120  # sleep through FLOOD_WAIT instead of crashing
    await client.start()
    chat = int(args.chat) if args.chat.lstrip("-").isdigit() else args.chat
    await client.get_input_entity(chat)  # fail fast on a wrong chat

    rates = Rates(args.star_usd)
    seen: dict[int, set[str]] = {}      # gift_id -> slugs already known
    collections: dict[int, str] = {}
    catalog_at = 0.0

    while True:
        if time.time() - catalog_at > CATALOG_REFRESH:
            catalog = await client(GetStarGiftsRequest(hash=0))
            collections = {g.id: g.title or str(g.id) for g in catalog.gifts
                           if getattr(g, "availability_resale", None)}
            catalog_at = time.time()
            log(f"collections on the market: {len(collections)}")
        rates.refresh()

        posted = 0
        for gift_id, name in collections.items():
            try:
                gifts = await newest(client, gift_id)
            except Exception as e:
                log(f"{name}: {e}")
                await asyncio.sleep(REQUEST_DELAY)
                continue
            await asyncio.sleep(REQUEST_DELAY)

            known = seen.get(gift_id)
            slugs = [g.slug for g in gifts]
            if known is None:  # first time we see this collection: snapshot, post nothing
                seen[gift_id] = set(slugs)
                continue
            # New listings sit on top; stop at the first known one so older lots that
            # move up after sales are not mistaken for new ones.
            fresh = []
            for g in gifts:
                if g.slug in known:
                    break
                fresh.append(g)
            known.update(slugs)

            for g in reversed(fresh):  # oldest first, so the chat reads chronologically
                row = parse_unique(g, name)
                rub = rates.to_rub(row)
                if rub is None or rub > args.max_rub:
                    continue
                await client.send_message(chat, format_message(row, rub), parse_mode="html")
                posted += 1
                log(f"posted {row['title']} #{row['num']} ≈ {rub:.0f} RUB")
                await asyncio.sleep(1)

        log(f"round done, posted {posted}")
        await asyncio.sleep(args.interval)


def main():
    p = argparse.ArgumentParser(description="Post new Telegram gift market listings to a chat")
    p.add_argument("--chat", required=True, help="where to post: @username, chat id or 'me'")
    p.add_argument("--max-rub", type=float, default=15000, help="price cap in RUB (default 15000)")
    p.add_argument("--star-usd", type=float, default=0.015,
                   help="USD per Telegram Star used for conversion (default 0.015)")
    p.add_argument("--interval", type=float, default=10, help="pause between rounds, seconds")
    p.add_argument("--session", default="gift_market", help="Telethon session file name")
    try:
        asyncio.run(run(p.parse_args()))
    except KeyboardInterrupt:
        pass


if __name__ == "__main__":
    main()
