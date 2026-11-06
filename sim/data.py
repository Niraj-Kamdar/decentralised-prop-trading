"""Binance spot 1m closes (data.binance.vision), cached as one .npy per symbol-month under sim/data/."""

import csv
import io
import urllib.request
import zipfile
from concurrent.futures import ThreadPoolExecutor
from datetime import datetime, timezone
from pathlib import Path

import numpy as np

DIR = Path(__file__).parent / "data"
URL = "https://data.binance.vision/data/spot/monthly/klines/{s}/1m/{s}-1m-{y}-{m:02d}.zip"
SYMBOLS = ("ETHUSDT", "BTCUSDT")  # asset index 0 = ETH, 1 = BTC
NAMES = ("ETH", "BTC")


def minute(day: str) -> int:
    return int(datetime.fromisoformat(day).replace(tzinfo=timezone.utc).timestamp()) // 60


def _months(t0: int, t1: int):
    a = datetime.fromtimestamp(t0 * 60, timezone.utc)
    b = datetime.fromtimestamp((t1 - 1) * 60, timezone.utc)
    y, m = a.year, a.month
    while (y, m) <= (b.year, b.month):
        yield y, m
        y, m = (y + 1, 1) if m == 12 else (y, m + 1)


def _month(sym: str, y: int, m: int) -> np.ndarray:
    f = DIR / f"{sym}-{y}-{m:02d}.npy"
    if not f.exists():
        DIR.mkdir(exist_ok=True)
        raw = urllib.request.urlopen(URL.format(s=sym, y=y, m=m), timeout=120).read()
        with zipfile.ZipFile(io.BytesIO(raw)) as z:
            rows = [r for r in csv.reader(io.TextIOWrapper(z.open(z.namelist()[0]))) if r[0].isdigit()]
        ts = np.array([int(r[0]) for r in rows], np.int64)
        ts = np.where(ts > 10**14, ts // 1000, ts)  # files from 2025 on are in microseconds
        np.save(f, np.stack([ts // 60_000, np.array([float(r[4]) for r in rows])]))
    return np.load(f)


def load(start: str, end: str, symbols=SYMBOLS) -> np.ndarray:
    """Closes on a gap-free UTC minute grid [start, end) as (len(symbols), minutes); exchange gaps forward-filled."""
    t0, t1 = minute(start), minute(end)
    jobs = [(s, y, m) for s in symbols for y, m in _months(t0, t1)]
    with ThreadPoolExecutor(8) as ex:
        months = list(ex.map(lambda j: _month(*j), jobs))
    out = np.full((len(symbols), t1 - t0), np.nan)
    for (s, _, _), arr in zip(jobs, months):
        i = arr[0].astype(np.int64) - t0
        keep = (i >= 0) & (i < t1 - t0)
        out[symbols.index(s), i[keep]] = arr[1][keep]
    for row in out:
        idx = np.maximum.accumulate(np.where(np.isnan(row), 0, np.arange(len(row))))
        row[:] = row[idx]
        row[np.isnan(row)] = row[~np.isnan(row)][0]  # leading gap: back-fill
    return out
