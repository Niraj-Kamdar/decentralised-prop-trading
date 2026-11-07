import test from "node:test";
import assert from "node:assert/strict";
import { histogram, pct, usd0 } from "./format";

test("usd0 formats whole dollars with small-loss zeroing", () => {
  assert.equal(usd0(1e-9), "$0");
  assert.equal(usd0(0.49), "$0");
  assert.equal(usd0(4932.63), "$4,933");
});

test("pct formats ratio to percentage", () => {
  assert.equal(pct(0.1246), "12.5%");
});

test("histogram bins values into edge buckets with inclusive final bin", () => {
  assert.deepEqual(
    histogram([1, 3, 5, 10, 20, 50], [1, 3, 5, 10, 20]),
    [1, 1, 1, 1, 2]
  );
});
