// Unit tests for local calendar dates (src/lib/local-dates.ts). No database needed.
import assert from "node:assert/strict";
import { describe, test } from "node:test";
import {
  addDays,
  daysInRange,
  isLocalDate,
  localDateOf,
  localTimeOf,
  rangeToInstants,
  resolvePeriod,
  startOfLocalDay,
} from "../src/lib/local-dates";

const IST = { utcOffsetMinutes: 330 };

describe("local dates", () => {
  test("only real YYYY-MM-DD calendar dates are accepted", () => {
    for (const ok of ["2026-10-05", "2024-02-29", "2026-12-31", "2026-01-01"]) assert.ok(isLocalDate(ok), ok);
    for (const bad of ["2026-02-29", "2026-13-01", "2026-00-10", "2026-10-32", "05/10/2026", "2026-10-5", "", "2026-10-05T00:00:00Z"]) {
      assert.ok(!isLocalDate(bad), bad);
    }
  });

  test("day arithmetic crosses months, years and leap days", () => {
    assert.equal(addDays("2026-10-01", -1), "2026-09-30");
    assert.equal(addDays("2026-12-31", 1), "2027-01-01");
    assert.equal(addDays("2024-02-28", 1), "2024-02-29");
    assert.equal(daysInRange("2026-10-05", "2026-10-05"), 1);
    assert.equal(daysInRange("2026-10-01", "2026-10-07"), 7);
    assert.equal(daysInRange("2026-10-07", "2026-10-01"), -5);
    assert.equal(daysInRange("2024-01-01", "2024-12-31"), 366);
  });

  test("the local date is the user's day, not the UTC day", () => {
    // 20:00 UTC on 4 October is 01:30 on 5 October in India.
    const instant = new Date("2026-10-04T20:00:00Z");
    assert.equal(localDateOf(instant, IST), "2026-10-05");
    assert.equal(localDateOf(instant, { timeZone: "Asia/Kolkata" }), "2026-10-05");
    assert.equal(localDateOf(instant, {}), "2026-10-04");
    assert.equal(localDateOf(new Date("2026-10-05T03:00:00Z"), { utcOffsetMinutes: -300 }), "2026-10-04");
    assert.equal(localTimeOf(instant, IST), "1:30 AM");
    assert.equal(localTimeOf(new Date("2026-10-05T06:30:00Z"), IST), "12:00 PM");
    assert.equal(localTimeOf(new Date("2026-10-05T18:30:00Z"), IST), "12:00 AM");
  });

  test("a local day starts at local midnight", () => {
    assert.equal(startOfLocalDay("2026-10-05", IST).toISOString(), "2026-10-04T18:30:00.000Z");
    assert.equal(startOfLocalDay("2026-10-05", { timeZone: "Asia/Kolkata" }).toISOString(), "2026-10-04T18:30:00.000Z");
    assert.equal(startOfLocalDay("2026-10-05", {}).toISOString(), "2026-10-05T00:00:00.000Z");
    assert.deepEqual(rangeToInstants({ startDate: "2026-10-01", endDate: "2026-10-07" }, IST), {
      since: new Date("2026-09-30T18:30:00.000Z"),
      before: new Date("2026-10-07T18:30:00.000Z"),
    });
  });

  test("days around a daylight-saving change keep their real length", () => {
    const ny = { timeZone: "America/New_York" };
    // Clocks went forward on 8 March 2026: that day is 23 hours long.
    assert.equal(startOfLocalDay("2026-03-08", ny).toISOString(), "2026-03-08T05:00:00.000Z");
    assert.equal(startOfLocalDay("2026-03-09", ny).toISOString(), "2026-03-09T04:00:00.000Z");
    // And back on 1 November 2026: 25 hours.
    assert.equal(startOfLocalDay("2026-11-02", ny).toISOString(), "2026-11-02T05:00:00.000Z");
  });

  test("periods on a Wednesday mid-month (weeks run Monday to Sunday)", () => {
    const today = "2026-10-07"; // Wednesday
    assert.deepEqual(resolvePeriod("today", today), { startDate: "2026-10-07", endDate: "2026-10-07" });
    assert.deepEqual(resolvePeriod("yesterday", today), { startDate: "2026-10-06", endDate: "2026-10-06" });
    assert.deepEqual(resolvePeriod("day_before_yesterday", today), { startDate: "2026-10-05", endDate: "2026-10-05" });
    assert.deepEqual(resolvePeriod("this_week", today), { startDate: "2026-10-05", endDate: "2026-10-07" });
    assert.deepEqual(resolvePeriod("last_week", today), { startDate: "2026-09-28", endDate: "2026-10-04" });
    assert.deepEqual(resolvePeriod("this_month", today), { startDate: "2026-10-01", endDate: "2026-10-07" });
    assert.deepEqual(resolvePeriod("last_month", today), { startDate: "2026-09-01", endDate: "2026-09-30" });
    assert.deepEqual(resolvePeriod("this_year", today), { startDate: "2026-01-01", endDate: "2026-10-07" });
    assert.deepEqual(resolvePeriod("last_year", today), { startDate: "2025-01-01", endDate: "2025-12-31" });
  });

  test("periods on a Monday, a Sunday and at the turn of the year", () => {
    assert.deepEqual(resolvePeriod("this_week", "2026-10-05"), { startDate: "2026-10-05", endDate: "2026-10-05" });
    assert.deepEqual(resolvePeriod("last_week", "2026-10-05"), { startDate: "2026-09-28", endDate: "2026-10-04" });
    assert.deepEqual(resolvePeriod("this_week", "2026-10-11"), { startDate: "2026-10-05", endDate: "2026-10-11" });
    assert.deepEqual(resolvePeriod("yesterday", "2026-01-01"), { startDate: "2025-12-31", endDate: "2025-12-31" });
    assert.deepEqual(resolvePeriod("last_month", "2026-01-15"), { startDate: "2025-12-01", endDate: "2025-12-31" });
    assert.deepEqual(resolvePeriod("last_month", "2024-03-31"), { startDate: "2024-02-01", endDate: "2024-02-29" });
    assert.deepEqual(resolvePeriod("last_week", "2026-01-01"), { startDate: "2025-12-22", endDate: "2025-12-28" });
  });
});
