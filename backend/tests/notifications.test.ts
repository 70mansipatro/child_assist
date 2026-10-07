// Integration tests for Phase 9 notifications: device registration, history, preferences, business
// events and FCM delivery. Runs the real app against the configured PostgreSQL database; FCM is
// replaced by a capturing sender, so nothing is pushed to real phones. Run with: npm test
import "dotenv/config";
import assert from "node:assert/strict";
import { randomUUID } from "node:crypto";
import type { Server } from "node:http";
import type { AddressInfo } from "node:net";
import { after, afterEach, before, beforeEach, describe, test } from "node:test";
import jwt from "jsonwebtoken";
import {
  ChatActionChannel,
  ChatActionStatus,
  ChatActionType,
  NotificationType,
  PermissionType,
} from "../generated/prisma/client";
import { createApp } from "../src/app";
import { env } from "../src/config/env";
import { prisma } from "../src/lib/prisma";
import { resetRateLimits } from "../src/middleware/rate-limit.middleware";
import { settlePasswordResetEmails } from "../src/modules/auth/password-reset.service";
import { completeHandoff, confirmPendingAction } from "../src/modules/chat/actions/pending-actions";
import { redact, setPushSender, type PushMessage, type PushResult } from "../src/modules/notifications/fcm.service";
import { notifyUser, settleNotifications } from "../src/modules/notifications/notification.service";
import { DeepLink, isSafeContent, templates } from "../src/modules/notifications/notification.types";
import { latestCodeFor, registerVerifiedUser, TEST_PASSWORD } from "./support/auth";

let server: Server;
let baseUrl: string;

interface TestUser {
  id: string;
  email: string;
  token: string;
}

const createdUserIds: string[] = [];

async function call(
  method: string,
  path: string,
  { token, body }: { token?: string; body?: unknown } = {},
): Promise<{ status: number; json: any; raw: string }> {
  const res = await fetch(`${baseUrl}${path}`, {
    method,
    headers: {
      "Content-Type": "application/json",
      ...(token ? { Authorization: `Bearer ${token}` } : {}),
    },
    body: body === undefined ? undefined : JSON.stringify(body),
  });
  const raw = await res.text();
  return { status: res.status, json: raw ? JSON.parse(raw) : null, raw };
}

async function newUser(name = "User"): Promise<TestUser> {
  const user = await registerVerifiedUser(call, name, `phase9-${randomUUID()}@test.local`);
  createdUserIds.push(user.id);
  // Registration logs in once, which records a "New login" alert; start each test from a clean slate.
  await settleNotifications();
  await prisma.notification.deleteMany({ where: { userId: user.id } });
  return user;
}

// ---------------------------------------------------------------------------------------------
// Capturing FCM

/** Every message "sent" to FCM. */
let pushes: PushMessage[] = [];
/** Tokens FCM should answer for with an error code instead of success. */
const pushErrors = new Map<string, string>();

function installFakeFcm(): void {
  setPushSender(async (messages) => {
    pushes.push(...messages);
    return messages.map((m): PushResult => {
      const code = pushErrors.get(m.token);
      if (!code) return { ok: true };
      return {
        ok: false,
        errorCode: code,
        invalidToken: code === "messaging/registration-token-not-registered" || code === "messaging/invalid-registration-token",
      };
    });
  });
}

const fcmToken = () => `fcm-test-${randomUUID()}:APA91b${randomUUID().replace(/-/g, "")}`;

async function registerDevice(user: TestUser, token = fcmToken(), platform = "ANDROID") {
  const res = await call("POST", "/api/notifications/devices", {
    token: user.token,
    body: { token, platform, appVersion: "1.0.0+1" },
  });
  assert.equal(res.status, 200, res.raw);
  return { id: res.json.device.id as string, token, res };
}

const pushesTo = (token: string) => pushes.filter((p) => p.token === token);
const notificationsOf = (userId: string) =>
  prisma.notification.findMany({ where: { userId }, orderBy: { createdAt: "asc" } });

before(async () => {
  server = createApp().listen(0);
  await new Promise<void>((resolve) => server.once("listening", resolve));
  baseUrl = `http://127.0.0.1:${(server.address() as AddressInfo).port}`;
});

beforeEach(() => {
  installFakeFcm();
  pushes = [];
  pushErrors.clear();
  resetRateLimits();
});

afterEach(async () => {
  await settleNotifications();
});

after(async () => {
  await settleNotifications();
  setPushSender(null);
  await prisma.user.deleteMany({ where: { id: { in: createdUserIds } } });
  await prisma.$disconnect();
  await new Promise<void>((resolve) => server.close(() => resolve()));
});

// ---------------------------------------------------------------------------------------------

describe("devices", () => {
  test("1. a device token is registered for the signed-in user only, and never echoed back", async () => {
    const user = await newUser();
    const { id, token, res } = await registerDevice(user);
    assert.equal(res.json.device.platform, "ANDROID");
    assert.equal(res.json.device.appVersion, "1.0.0+1");
    assert.equal(res.json.device.enabled, true);
    assert.ok(!res.raw.includes(token), "the token must not be returned");
    assert.ok(!/userId/.test(res.raw));
    const row = await prisma.notificationDevice.findUniqueOrThrow({ where: { id } });
    assert.equal(row.userId, user.id);
    assert.equal(row.token, token);
  });

  test("2. registering the same token again updates the one row instead of adding another", async () => {
    const user = await newUser();
    const token = fcmToken();
    const first = await registerDevice(user, token);
    const again = await call("POST", "/api/notifications/devices", {
      token: user.token,
      body: { token, platform: "ANDROID", appVersion: "1.0.1+2" },
    });
    assert.equal(again.status, 200, again.raw);
    assert.equal(again.json.device.id, first.id);
    assert.equal(again.json.device.appVersion, "1.0.1+2");
    assert.equal(await prisma.notificationDevice.count({ where: { token } }), 1);
  });

  test("3. a user with several devices gets the notification on every one", async () => {
    const user = await newUser();
    const phone = await registerDevice(user);
    const tablet = await registerDevice(user, fcmToken(), "IOS");
    const outcome = await notifyUser(user.id, templates.test());
    assert.equal(outcome.status, "created");
    assert.equal(pushesTo(phone.token).length, 1);
    assert.equal(pushesTo(tablet.token).length, 1);
  });

  test("4. a device can be removed once; removing it again is 404", async () => {
    const user = await newUser();
    const { id } = await registerDevice(user);
    const del = await call("DELETE", `/api/notifications/devices/${id}`, { token: user.token });
    assert.equal(del.status, 200, del.raw);
    assert.equal(await prisma.notificationDevice.count({ where: { id } }), 0);
    const again = await call("DELETE", `/api/notifications/devices/${id}`, { token: user.token });
    assert.equal(again.status, 404);
  });

  test("5. a user cannot remove another user's device", async () => {
    const a = await newUser("A");
    const b = await newUser("B");
    const { id } = await registerDevice(a);
    const res = await call("DELETE", `/api/notifications/devices/${id}`, { token: b.token });
    assert.equal(res.status, 404);
    assert.equal(await prisma.notificationDevice.count({ where: { id, userId: a.id } }), 1);
  });

  test("a refreshed token is registered for the same user; the stale one is cleaned up by FCM", async () => {
    const user = await newUser();
    const old = await registerDevice(user);
    const refreshed = await registerDevice(user);
    assert.notEqual(refreshed.id, old.id);
    assert.equal(await prisma.notificationDevice.count({ where: { userId: user.id } }), 2);
    pushErrors.set(old.token, "messaging/registration-token-not-registered");
    await notifyUser(user.id, templates.test());
    assert.equal(pushesTo(refreshed.token).length, 1);
    assert.equal(await prisma.notificationDevice.count({ where: { id: old.id } }), 0);
    assert.equal(await prisma.notificationDevice.count({ where: { userId: user.id } }), 1);
  });

  test("re-registering updates lastSeenAt and metadata, never userId from elsewhere", async () => {
    const user = await newUser();
    const token = fcmToken();
    const first = await registerDevice(user, token);
    const before = await prisma.notificationDevice.findUniqueOrThrow({ where: { id: first.id } });
    await new Promise((r) => setTimeout(r, 20));
    await call("POST", "/api/notifications/devices", { token: user.token, body: { token, platform: "ANDROID", appVersion: "2.0.0+5" } });
    const after = await prisma.notificationDevice.findUniqueOrThrow({ where: { id: first.id } });
    assert.equal(after.appVersion, "2.0.0+5");
    assert.ok(after.lastSeenAt > before.lastSeenAt);
    assert.equal(after.userId, user.id);
  });

  test("an inactive (disabled) device is not pushed to, and re-registering enables it", async () => {
    const user = await newUser();
    const device = await registerDevice(user);
    await prisma.notificationDevice.update({ where: { id: device.id }, data: { enabled: false } });
    await notifyUser(user.id, templates.test());
    assert.equal(pushesTo(device.token).length, 0);
    await registerDevice(user, device.token);
    await notifyUser(user.id, templates.test());
    assert.equal(pushesTo(device.token).length, 1);
  });

  test("registration without a valid JWT is refused and stores nothing", async () => {
    const token = fcmToken();
    for (const auth of [undefined, "garbage"]) {
      const res = await call("POST", "/api/notifications/devices", { token: auth, body: { token, platform: "ANDROID" } });
      assert.equal(res.status, 401);
    }
    assert.equal(await prisma.notificationDevice.count({ where: { token } }), 0);
  });

  test("a userId in the registration body is refused", async () => {
    const a = await newUser("A");
    const b = await newUser("B");
    const res = await call("POST", "/api/notifications/devices", {
      token: a.token,
      body: { token: fcmToken(), platform: "ANDROID", userId: b.id },
    });
    assert.equal(res.status, 400);
    assert.equal(await prisma.notificationDevice.count({ where: { userId: b.id } }), 0);
  });

  test("malformed tokens and platforms are refused", async () => {
    const user = await newUser();
    for (const body of [
      { token: "short", platform: "ANDROID" },
      { token: `${fcmToken()} <script>`, platform: "ANDROID" },
      { token: fcmToken(), platform: "WINDOWS" },
      {},
    ]) {
      const res = await call("POST", "/api/notifications/devices", { token: user.token, body });
      assert.equal(res.status, 400, JSON.stringify(body));
    }
  });
});

describe("sending", () => {
  test("6. a notification is saved to history and pushed with its id, type and deep link", async () => {
    const user = await newUser();
    const { token } = await registerDevice(user);
    const outcome = await notifyUser(user.id, templates.trackingStarted());
    assert.equal(outcome.status, "created");
    const [row] = await notificationsOf(user.id);
    assert.equal(row.type, NotificationType.TRACKING_STARTED);
    assert.equal(row.title, "Location tracking started");
    assert.equal(row.readAt, null);

    const [push] = pushesTo(token);
    assert.equal(push.title, row.title);
    assert.equal(push.body, row.body);
    assert.deepEqual(push.data, {
      notificationId: row.id,
      type: "TRACKING_STARTED",
      category: "LOCATION",
      deepLink: DeepLink.location,
    });
    assert.equal(push.androidChannelId, "child_assist_location");
    assert.equal(push.highPriority, false);
  });

  test("security alerts use the high-priority security channel", async () => {
    const user = await newUser();
    const { token } = await registerDevice(user);
    await notifyUser(user.id, templates.passwordChanged());
    const [push] = pushesTo(token);
    assert.equal(push.androidChannelId, "child_assist_security");
    assert.equal(push.highPriority, true);
    assert.equal(push.data.deepLink, DeepLink.security);
  });

  test("7. a switched-off category is neither saved nor pushed", async () => {
    const user = await newUser();
    const { token } = await registerDevice(user);
    const off = await call("PATCH", "/api/notifications/preferences", {
      token: user.token,
      body: { locationEnabled: false },
    });
    assert.equal(off.status, 200, off.raw);
    assert.equal(off.json.preferences.locationEnabled, false);

    const outcome = await notifyUser(user.id, templates.trackingStarted());
    assert.deepEqual(outcome, { status: "skipped", reason: "preference-disabled" });
    assert.equal((await notificationsOf(user.id)).length, 0);
    assert.equal(pushesTo(token).length, 0);

    // Other categories are unaffected.
    assert.equal((await notifyUser(user.id, templates.appUpdate())).status, "created");
  });

  test("8. security alerts cannot be switched off and are delivered regardless", async () => {
    const user = await newUser();
    const { token } = await registerDevice(user);
    const res = await call("PATCH", "/api/notifications/preferences", {
      token: user.token,
      body: { securityEnabled: false },
    });
    assert.equal(res.status, 400);
    assert.equal(res.json.code, "MANDATORY_CATEGORY");

    // Even a row written directly with security off is ignored.
    await prisma.notificationPreference.upsert({
      where: { userId: user.id },
      create: { userId: user.id, securityEnabled: false },
      update: { securityEnabled: false },
    });
    const prefs = await call("GET", "/api/notifications/preferences", { token: user.token });
    assert.equal(prefs.json.preferences.securityEnabled, true);
    assert.deepEqual(prefs.json.preferences.mandatory, ["SECURITY"]);
    assert.equal((await notifyUser(user.id, templates.newLogin())).status, "created");
    assert.equal(pushesTo(token).length, 1);
  });

  test("preferences default to all on and keep unchanged switches", async () => {
    const user = await newUser();
    const initial = await call("GET", "/api/notifications/preferences", { token: user.token });
    assert.equal(initial.status, 200);
    for (const key of ["securityEnabled", "accountEnabled", "permissionEnabled", "locationEnabled", "chatEnabled", "communicationEnabled", "systemEnabled"]) {
      assert.equal(initial.json.preferences[key], true, key);
    }
    await call("PATCH", "/api/notifications/preferences", { token: user.token, body: { chatEnabled: false } });
    const next = await call("PATCH", "/api/notifications/preferences", { token: user.token, body: { systemEnabled: false } });
    assert.equal(next.json.preferences.chatEnabled, false);
    assert.equal(next.json.preferences.systemEnabled, false);
    assert.equal(next.json.preferences.locationEnabled, true);
    const empty = await call("PATCH", "/api/notifications/preferences", { token: user.token, body: {} });
    assert.equal(empty.status, 400);
  });

  test("17. tokens FCM reports as invalid are removed; other devices keep receiving", async () => {
    const user = await newUser();
    const stale = await registerDevice(user);
    const good = await registerDevice(user);
    pushErrors.set(stale.token, "messaging/registration-token-not-registered");
    const outcome = await notifyUser(user.id, templates.test());
    assert.equal(outcome.status, "created");
    if (outcome.status === "created") {
      assert.equal(outcome.sent, 1);
      assert.equal(outcome.removedDevices, 1);
    }
    assert.equal(await prisma.notificationDevice.count({ where: { id: stale.id } }), 0);
    assert.equal(await prisma.notificationDevice.count({ where: { id: good.id } }), 1);

    pushes = [];
    await notifyUser(user.id, templates.test());
    assert.equal(pushesTo(stale.token).length, 0);
    assert.equal(pushesTo(good.token).length, 1);
  });

  test("18. a temporary FCM failure keeps the device, and the notification is still in history", async () => {
    const user = await newUser();
    const device = await registerDevice(user);
    pushErrors.set(device.token, "messaging/internal-error");
    const outcome = await notifyUser(user.id, templates.test());
    assert.equal(outcome.status, "created");
    if (outcome.status === "created") {
      assert.equal(outcome.sent, 0);
      assert.equal(outcome.failed, 1);
      assert.equal(outcome.removedDevices, 0);
    }
    assert.equal(await prisma.notificationDevice.count({ where: { id: device.id } }), 1);
    assert.equal((await notificationsOf(user.id)).length, 1);
  });

  test("50. a failing push never fails the business operation (password reset still succeeds)", async () => {
    const user = await newUser();
    await registerDevice(user);
    setPushSender(async () => {
      throw new Error("FCM unreachable");
    });
    assert.equal((await call("POST", "/api/auth/forgot-password", { body: { email: user.email } })).status, 200);
    await settlePasswordResetEmails();
    const verify = await call("POST", "/api/auth/verify-reset-code", { body: { email: user.email, code: latestCodeFor(user.email) } });
    assert.equal(verify.status, 200, verify.raw);
    const reset = await call("POST", "/api/auth/reset-password", {
      body: { resetToken: verify.json.resetToken, newPassword: "newpassword456", confirmPassword: "newpassword456" },
    });
    assert.equal(reset.status, 200, reset.raw);
    await settleNotifications();
    const types = (await notificationsOf(user.id)).map((n) => n.type);
    assert.deepEqual(types, [NotificationType.PASSWORD_RESET]);
    const login = await call("POST", "/api/auth/login", { body: { email: user.email, password: "newpassword456" } });
    assert.equal(login.status, 200);
  });

  test("21. the same business event notifies once (dedupe key)", async () => {
    const user = await newUser();
    const { token } = await registerDevice(user);
    const first = await notifyUser(user.id, templates.emailSent(), { dedupeKey: "email-action:abc" });
    const second = await notifyUser(user.id, templates.emailSent(), { dedupeKey: "email-action:abc" });
    assert.equal(first.status, "created");
    assert.deepEqual(second, { status: "skipped", reason: "duplicate" });
    assert.equal(pushesTo(token).length, 1);
    assert.equal((await notificationsOf(user.id)).length, 1);
  });
});

describe("business events", () => {
  test("a login alerts the account's signed-in devices without device or place details", async () => {
    const user = await newUser();
    const { token } = await registerDevice(user);
    const login = await call("POST", "/api/auth/login", { body: { email: user.email, password: TEST_PASSWORD } });
    assert.equal(login.status, 200);
    await settleNotifications();
    const [push] = pushesTo(token);
    assert.equal(push.title, "New login to Child Assist");
    assert.equal(push.body, "A new device signed in to your account.");
    assert.equal(push.data.deepLink, DeepLink.security);
    assert.ok(!JSON.stringify(push).includes(login.json.token), "never the JWT");
  });

  test("a permission taken away notifies once, naming only the permission", async () => {
    const user = await newUser();
    const { token } = await registerDevice(user);
    const set = (status: string) => call("PATCH", "/api/permissions/LOCATION", { token: user.token, body: { status } });
    assert.equal((await set("GRANTED")).status, 200);
    assert.equal((await set("DENIED")).status, 200);
    assert.equal((await set("DENIED")).status, 200);
    await settleNotifications();
    const rows = await notificationsOf(user.id);
    assert.equal(rows.length, 1);
    assert.equal(rows[0].type, NotificationType.PERMISSION_CHANGED);
    assert.equal(rows[0].title, "Location permission changed");
    assert.equal(rows[0].body, "Location access is currently disabled.");
    assert.equal(rows[0].deepLink, DeepLink.locationPermission);
    assert.equal(pushesTo(token).length, 1);

    // A first report of "denied" (never granted before) is not a change worth telling.
    const mic = await call("PATCH", "/api/permissions/MICROPHONE", { token: user.token, body: { status: "DENIED" } });
    assert.equal(mic.status, 200);
    await settleNotifications();
    assert.equal((await notificationsOf(user.id)).length, 1);
  });

  test("tracking state: one notification per real change, none for repeated callbacks", async () => {
    const user = await newUser();
    const { token } = await registerDevice(user);
    const report = async (state: string) => {
      const res = await call("POST", "/api/location/tracking-status", { token: user.token, body: { state } });
      assert.equal(res.status, 200, res.raw);
      return res.json.notified as boolean;
    };
    assert.equal(await report("STOPPED"), false, "nothing to stop yet");
    assert.equal(await report("STARTED"), true);
    assert.equal(await report("STARTED"), false);
    assert.equal(await report("STARTED"), false);
    assert.equal(await report("PAUSED"), true);
    assert.equal(await report("PAUSED"), false);
    assert.equal(await report("STARTED"), true);
    assert.equal(await report("STOPPED"), true);
    const types = (await notificationsOf(user.id)).map((n) => n.type);
    assert.deepEqual(types, ["TRACKING_STARTED", "TRACKING_PAUSED", "TRACKING_STARTED", "TRACKING_STOPPED"]);
    assert.equal(pushesTo(token).length, 4);
    const paused = pushesTo(token)[1];
    assert.equal(paused.body, "Location access is required to continue automatic travel history.");
    assert.equal(paused.data.deepLink, DeepLink.locationPermission);

    const bad = await call("POST", "/api/location/tracking-status", { token: user.token, body: { state: "MOVING" } });
    assert.equal(bad.status, 400);
  });

  test("concurrent identical tracking reports create a single notification", async () => {
    const user = await newUser();
    await Promise.all(
      Array.from({ length: 5 }, () =>
        call("POST", "/api/location/tracking-status", { token: user.token, body: { state: "STARTED" } }),
      ),
    );
    assert.equal((await notificationsOf(user.id)).length, 1);
  });

  test("9/40. automatic places are saved silently; one daily notice carries no coordinates or address", async () => {
    const user = await newUser();
    const { token } = await registerDevice(user);
    const now = Date.now();
    const points = [
      { latitude: 20.2961234, longitude: 85.8245678, placeName: "Secret Cafe", street: "12 Hidden Lane" },
      { latitude: 20.3961234, longitude: 85.9245678, placeName: "Another Place", street: "99 Main Street" },
      { latitude: 20.4961234, longitude: 85.7245678, placeName: "Third Place", street: "7 Side Road" },
    ];
    for (const [i, p] of points.entries()) {
      const res = await call("POST", "/api/location", {
        token: user.token,
        body: { ...p, source: "AUTOMATIC", capturedAt: new Date(now - (3 - i) * 3_600_000).toISOString() },
      });
      assert.equal(res.status, 201, res.raw);
    }
    await settleNotifications();
    const rows = await notificationsOf(user.id);
    assert.equal(rows.length, 1, "one notice, not one per reading");
    assert.equal(rows[0].type, NotificationType.TRAVEL_HISTORY_UPDATED);
    const payload = JSON.stringify(pushesTo(token)) + JSON.stringify(rows);
    for (const secret of ["20.29", "85.82", "20.39", "Secret Cafe", "Hidden Lane", "Main Street", "latitude", "longitude"]) {
      assert.ok(!payload.includes(secret), `push leaked ${secret}`);
    }
    assert.equal(pushesTo(token)[0].body, "Your travel history has new activity.");

    // Manual saves never notify.
    await prisma.notification.deleteMany({ where: { userId: user.id } });
    await call("POST", "/api/location", {
      token: user.token,
      body: { latitude: 21.1, longitude: 86.1, source: "MANUAL", capturedAt: new Date().toISOString() },
    });
    await settleNotifications();
    assert.equal((await notificationsOf(user.id)).length, 0);
  });

  async function actionFor(user: TestUser, channel: ChatActionChannel, fields: Record<string, unknown>) {
    const conversation = await prisma.chatConversation.create({ data: { userId: user.id, title: "Test" } });
    return prisma.chatAction.create({
      data: {
        id: `act-${randomUUID()}`,
        userId: user.id,
        conversationId: conversation.id,
        type: channel === ChatActionChannel.EMAIL ? ChatActionType.SEND_EMAIL : ChatActionType.SEND_WHATSAPP,
        channel,
        expiresAt: new Date(Date.now() + 600_000),
        ...fields,
      },
    });
  }

  test("10/11/41/42. a confirmed email notifies 'Email sent' without recipient, subject or content", async () => {
    const user = await newUser();
    const { token } = await registerDevice(user);
    const action = await actionFor(user, ChatActionChannel.EMAIL, {
      recipientName: "Mansi",
      recipientAddress: "mansi.private@example.com",
      subject: "Pickup secret",
      message: "Here is the private phone number 9876543210 and my location.",
    });
    // Nothing before confirmation.
    await settleNotifications();
    assert.equal(pushesTo(token).length, 0);

    const outcome = await confirmPendingAction(user.id, action.id);
    assert.equal(outcome.status, ChatActionStatus.COMPLETED);
    await settleNotifications();
    const [push] = pushesTo(token);
    assert.equal(push.title, "Email sent");
    assert.equal(push.body, "Your email was sent successfully.");
    assert.equal(push.data.deepLink, DeepLink.chat);
    const payload = JSON.stringify(push);
    for (const secret of ["mansi.private", "Mansi", "Pickup secret", "9876543210", "private phone"]) {
      assert.ok(!payload.includes(secret), `push leaked ${secret}`);
    }
  });

  test("a WhatsApp handoff says 'WhatsApp opened', never 'sent', and carries no phone number", async () => {
    const user = await newUser();
    const { token } = await registerDevice(user);
    const action = await actionFor(user, ChatActionChannel.WHATSAPP, {
      status: ChatActionStatus.CONFIRMED,
      recipientName: "Ravi",
      recipientAddress: "+919876543210",
      message: "Ravi's number is +91 99999 88888",
    });
    await completeHandoff(user.id, action.id, "whatsapp_opened");
    await settleNotifications();
    const [push] = pushesTo(token);
    assert.equal(push.title, "WhatsApp opened");
    assert.equal(push.body, "Review the message and tap Send in WhatsApp.");
    const payload = JSON.stringify(push);
    assert.doesNotMatch(payload, /\bsent\b/i);
    for (const secret of ["9876543210", "99999", "Ravi"]) assert.ok(!payload.includes(secret), `push leaked ${secret}`);
  });

  test("every template is fixed copy with no personal data, and unsafe content is refused", async () => {
    const all = [
      ...Object.entries(templates)
        .filter(([name]) => name !== "permissionDisabled")
        .map(([, make]) => (make as () => ReturnType<typeof templates.test>)()),
      ...Object.values(PermissionType).map((p) => templates.permissionDisabled(p)),
    ];
    for (const content of all) {
      assert.ok(isSafeContent(content), content.title);
      assert.ok(content.deepLink.startsWith("childassist://"), content.title);
    }
    // 42: never the AI's answer.
    assert.equal(templates.chatReplyReady().body, "Your requested information is ready.");

    const user = await newUser();
    for (const body of ["Call +91 98765 43210", "Mail mansi@example.com", "You were at 20.2961, 85.8245", "Your code is 482913"]) {
      await assert.rejects(notifyUser(user.id, { ...templates.test(), body }), /unsafe/);
    }
    assert.equal((await notificationsOf(user.id)).length, 0);
  });
});

describe("FCM diagnostics", () => {
  test("error messages are logged without anything token-like", () => {
    const fcmTok = `dGhpcy1pcy1hLWZha2UtZmNtLXRva2Vu:APA91b${"x".repeat(120)}`;
    const oauth = `ya29.${"a1B2c3D4".repeat(10)}`;
    const out = redact(`Requested entity was not found for ${fcmTok}; bearer ${oauth}`);
    assert.ok(!out.includes("APA91b"));
    assert.ok(!out.includes("ya29."));
    assert.match(out, /Requested entity was not found/);
  });
});

describe("history", () => {
  async function seed(user: TestUser, count: number): Promise<void> {
    for (let i = 0; i < count; i++) await notifyUser(user.id, templates.test());
  }

  test("12/13. the list is newest first, paginated, with the unread count", async () => {
    const user = await newUser();
    await seed(user, 5);
    const page1 = await call("GET", "/api/notifications?limit=3", { token: user.token });
    assert.equal(page1.status, 200, page1.raw);
    assert.equal(page1.json.notifications.length, 3);
    assert.equal(page1.json.hasMore, true);
    assert.equal(page1.json.unreadCount, 5);
    const n = page1.json.notifications[0];
    assert.deepEqual(Object.keys(n).sort(), ["body", "category", "createdAt", "deepLink", "id", "read", "readAt", "title", "type"]);
    const times = page1.json.notifications.map((x: any) => Date.parse(x.createdAt));
    assert.deepEqual(times, [...times].sort((a, b) => b - a));

    const page2 = await call("GET", `/api/notifications?limit=3&before=${page1.json.notifications[2].id}`, { token: user.token });
    assert.equal(page2.json.notifications.length, 2);
    assert.equal(page2.json.hasMore, false);
    const ids = new Set([...page1.json.notifications, ...page2.json.notifications].map((x: any) => x.id));
    assert.equal(ids.size, 5);

    const count = await call("GET", "/api/notifications/unread-count", { token: user.token });
    assert.deepEqual(count.json, { unreadCount: 5 });
  });

  test("14/15. mark one read, then all read", async () => {
    const user = await newUser();
    await seed(user, 3);
    const list = await call("GET", "/api/notifications", { token: user.token });
    const id = list.json.notifications[0].id;
    const read = await call("PATCH", `/api/notifications/${id}/read`, { token: user.token });
    assert.equal(read.status, 200, read.raw);
    assert.equal(read.json.notification.read, true);
    const readAt = read.json.notification.readAt;
    // Marking again keeps the original time.
    const again = await call("PATCH", `/api/notifications/${id}/read`, { token: user.token });
    assert.equal(again.json.notification.readAt, readAt);
    assert.equal((await call("GET", "/api/notifications/unread-count", { token: user.token })).json.unreadCount, 2);

    const unreadOnly = await call("GET", "/api/notifications?unread=true", { token: user.token });
    assert.equal(unreadOnly.json.notifications.length, 2);

    const all = await call("PATCH", "/api/notifications/read-all", { token: user.token });
    assert.deepEqual(all.json, { updated: 2 });
    assert.equal((await call("GET", "/api/notifications/unread-count", { token: user.token })).json.unreadCount, 0);
  });

  test("16. each notification keeps its deep link for the app to route", async () => {
    const user = await newUser();
    await notifyUser(user.id, templates.test(DeepLink.location));
    await notifyUser(user.id, templates.whatsappOpened());
    const list = await call("GET", "/api/notifications", { token: user.token });
    assert.deepEqual(
      list.json.notifications.map((n: any) => n.deepLink).sort(),
      [DeepLink.chat, DeepLink.location].sort(),
    );
  });

  test("history can be deleted one by one or cleared", async () => {
    const user = await newUser();
    await seed(user, 3);
    const list = await call("GET", "/api/notifications", { token: user.token });
    const del = await call("DELETE", `/api/notifications/${list.json.notifications[0].id}`, { token: user.token });
    assert.equal(del.status, 200);
    const clear = await call("DELETE", "/api/notifications", { token: user.token });
    assert.deepEqual(clear.json, { deleted: 2 });
    assert.equal((await notificationsOf(user.id)).length, 0);
  });
});

describe("accounts and security", () => {
  test("19. after logout the device is removed and receives nothing more", async () => {
    const user = await newUser();
    const device = await registerDevice(user);
    assert.equal((await call("DELETE", `/api/notifications/devices/${device.id}`, { token: user.token })).status, 200);
    assert.equal((await call("POST", "/api/auth/logout", { token: user.token })).status, 200);
    await notifyUser(user.id, templates.test());
    assert.equal(pushesTo(device.token).length, 0);
    // Still in history for the next time they sign in.
    assert.equal((await notificationsOf(user.id)).length, 1);
  });

  test("20/37. account switching: the phone's token moves to the new account", async () => {
    const a = await newUser("A");
    const b = await newUser("B");
    const token = fcmToken();
    const deviceA = await registerDevice(a, token);
    // A logs out without the app reaching the server; B signs in on the same phone.
    const deviceB = await registerDevice(b, token);
    assert.equal(deviceB.id, deviceA.id, "same phone, same row");
    assert.equal(await prisma.notificationDevice.count({ where: { token } }), 1);

    await notifyUser(a.id, templates.test());
    assert.equal(pushesTo(token).length, 0, "A's notifications never reach B's session");
    await notifyUser(b.id, templates.test());
    assert.equal(pushesTo(token).length, 1);

    // A's late logout call cannot remove B's registration.
    const late = await call("DELETE", `/api/notifications/devices/${deviceA.id}`, { token: a.token });
    assert.equal(late.status, 404);
    assert.equal(await prisma.notificationDevice.count({ where: { token, userId: b.id } }), 1);

    // Each account only ever sees its own history.
    const listB = await call("GET", "/api/notifications", { token: b.token });
    assert.equal(listB.json.notifications.length, 1);
    const listA = await call("GET", "/api/notifications", { token: a.token });
    assert.equal(listA.json.notifications.length, 1);
    assert.notEqual(listA.json.notifications[0].id, listB.json.notifications[0].id);
  });

  test("22/39. notification endpoints are rate limited per account", async () => {
    const user = await newUser();
    const other = await newUser();
    let last = 0;
    for (let i = 0; i < 21; i++) {
      last = (await call("POST", "/api/notifications/devices", { token: user.token, body: { token: fcmToken(), platform: "ANDROID" } })).status;
    }
    assert.equal(last, 429);
    // Another account is not affected.
    assert.equal((await call("POST", "/api/notifications/devices", { token: other.token, body: { token: fcmToken(), platform: "ANDROID" } })).status, 200);

    let prefs = 0;
    for (let i = 0; i < 31; i++) {
      prefs = (await call("PATCH", "/api/notifications/preferences", { token: user.token, body: { chatEnabled: i % 2 === 0 } })).status;
    }
    assert.equal(prefs, 429);
  });

  test("23. every endpoint needs a valid, unexpired JWT", async () => {
    const user = await newUser();
    const expired = jwt.sign({}, env.jwtSecret, { algorithm: "HS256", subject: user.id, jwtid: randomUUID(), expiresIn: -60 });
    const forged = jwt.sign({}, "not-the-real-secret-not-the-real-secret", { algorithm: "HS256", subject: user.id });
    const endpoints: [string, string, unknown?][] = [
      ["GET", "/api/notifications"],
      ["GET", "/api/notifications/unread-count"],
      ["PATCH", "/api/notifications/read-all"],
      ["PATCH", `/api/notifications/${randomUUID()}/read`],
      ["GET", "/api/notifications/preferences"],
      ["PATCH", "/api/notifications/preferences", { chatEnabled: false }],
      ["POST", "/api/notifications/devices", { token: fcmToken(), platform: "ANDROID" }],
      ["DELETE", `/api/notifications/devices/${randomUUID()}`],
      ["POST", "/api/location/tracking-status", { state: "STARTED" }],
    ];
    for (const [method, path, body] of endpoints) {
      for (const token of [undefined, "garbage", expired, forged]) {
        const res = await call(method, path, { token, body });
        assert.equal(res.status, 401, `${method} ${path} with ${token ? "bad" : "no"} token`);
      }
    }
  });

  test("24/54. a user cannot read or change another user's notifications", async () => {
    const a = await newUser("A");
    const b = await newUser("B");
    await notifyUser(b.id, templates.test());
    const [bNotification] = await notificationsOf(b.id);

    const probe = await call("GET", `/api/notifications?userId=${b.id}`, { token: a.token });
    assert.equal(probe.status, 400, "a userId parameter is rejected, never honoured");
    const countProbe = await call("GET", `/api/notifications/unread-count?userId=${b.id}`, { token: a.token });
    assert.equal(countProbe.status, 400);

    const listA = await call("GET", "/api/notifications", { token: a.token });
    assert.equal(listA.json.notifications.length, 0);
    assert.equal((await call("PATCH", `/api/notifications/${bNotification.id}/read`, { token: a.token })).status, 404);
    assert.equal((await call("DELETE", `/api/notifications/${bNotification.id}`, { token: a.token })).status, 404);
    // A cursor from another account is not accepted either.
    assert.equal((await call("GET", `/api/notifications?before=${bNotification.id}`, { token: a.token })).status, 400);
    await call("PATCH", "/api/notifications/read-all", { token: a.token });
    await call("DELETE", "/api/notifications", { token: a.token });

    const after = await prisma.notification.findUniqueOrThrow({ where: { id: bNotification.id } });
    assert.equal(after.readAt, null);
  });

  test("25. a user cannot change another user's preferences", async () => {
    const a = await newUser("A");
    const b = await newUser("B");
    const withId = await call("PATCH", "/api/notifications/preferences", {
      token: a.token,
      body: { userId: b.id, chatEnabled: false },
    });
    assert.equal(withId.status, 400);
    await call("PATCH", "/api/notifications/preferences", { token: a.token, body: { chatEnabled: false } });
    const prefsB = await call("GET", "/api/notifications/preferences", { token: b.token });
    assert.equal(prefsB.json.preferences.chatEnabled, true);
    assert.equal(await prisma.notificationPreference.count({ where: { userId: b.id } }), 0);
  });
});
