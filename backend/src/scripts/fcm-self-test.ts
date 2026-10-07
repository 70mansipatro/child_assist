// Development-only check of the keyless FCM credential, step by step. Prints only identities,
// scopes, expiry and error codes; never an access token, refresh token or FCM token.
//
//   npm run fcm:selftest [-- --email someone@example.com]
//
// 1. Mints a short-lived token for FCM_IMPERSONATE_SERVICE_ACCOUNT from Application Default
//    Credentials, and reports which account it belongs to, its scope and its lifetime.
// 2. Asks FCM to validate (dry run, nothing is delivered) a message for project FCM_PROJECT_ID:
//    to the account's first registered phone with --email, otherwise to a dummy token (an
//    "invalid registration token" answer then proves the credential and project are accepted).
import "dotenv/config";
import { getMessaging } from "firebase-admin/messaging";
import { initializeApp, type App } from "firebase-admin/app";
import { Impersonated } from "google-auth-library";
import { pushConfig } from "../config/env";
import { prisma } from "../lib/prisma";
import { FCM_SCOPE, impersonatedClient, redact } from "../modules/notifications/fcm.service";

const EMAIL_SCOPE = "https://www.googleapis.com/auth/userinfo.email";

async function tokenInfo(token: string): Promise<Record<string, string>> {
  const res = await fetch("https://oauth2.googleapis.com/tokeninfo", {
    method: "POST",
    headers: { "Content-Type": "application/x-www-form-urlencoded" },
    body: new URLSearchParams({ access_token: token }),
  });
  return (await res.json()) as Record<string, string>;
}

async function main(): Promise<void> {
  const { config, error } = pushConfig();
  if (!config) throw new Error(`Push is not configured: ${error}`);
  const target = config.impersonateServiceAccount;
  if (!target) throw new Error("FCM_IMPERSONATE_SERVICE_ACCOUNT is not set (this check is for the keyless setup)");
  console.log(`project: ${config.projectId}`);
  console.log(`target service account: ${target}`);

  // 1. Token for the service account, plus the identity it belongs to.
  const client = await impersonatedClient(target, config.projectId);
  const { token } = await client.getAccessToken();
  if (!token) throw new Error("no access token returned");
  const info = await tokenInfo(token);
  console.log(`1a. FCM token minted: scope=${info.scope} expires_in=${info.expires_in}s`);
  const identityClient = new Impersonated({
    sourceClient: (client as unknown as { sourceClient: Impersonated["sourceClient"] }).sourceClient,
    targetPrincipal: target,
    targetScopes: [FCM_SCOPE, EMAIL_SCOPE],
    lifetime: 300,
    delegates: [],
  });
  const identity = await tokenInfo((await identityClient.getAccessToken()).token ?? "");
  console.log(`1b. token belongs to: ${identity.email} (${identity.email === target ? "matches target" : "DOES NOT match target"})`);

  // 2. FCM dry run with the same credential the backend uses.
  let deviceToken = "self-test-dummy-token";
  const email = process.argv.includes("--email") ? process.argv[process.argv.indexOf("--email") + 1] : undefined;
  if (email) {
    const device = await prisma.notificationDevice.findFirst({
      where: { user: { email: email.trim().toLowerCase() }, enabled: true },
      orderBy: { lastSeenAt: "desc" },
      select: { token: true },
    });
    if (!device) throw new Error("that account has no registered phone");
    deviceToken = device.token;
  }
  const app: App = initializeApp(
    {
      projectId: config.projectId,
      credential: {
        async getAccessToken() {
          const t = await client.getAccessToken();
          return { access_token: t.token ?? "", expires_in: 300 };
        },
      },
    },
    "fcm-self-test",
  );
  try {
    await getMessaging(app).send({ token: deviceToken, notification: { title: "Self-test", body: "Dry run" } }, true);
    console.log(`2. FCM dry run accepted for ${email ? "the registered phone" : "a message"} (nothing delivered)`);
  } catch (err) {
    const e = err as { code?: string; message?: string };
    const authOk = !email && e.code === "messaging/invalid-argument";
    console.log(`2. FCM dry run: ${e.code}: ${redact(e.message ?? "")}`);
    console.log(authOk ? "   -> credential and project accepted (the dummy token was rejected as expected)" : "   -> FAILED");
    if (!authOk) process.exitCode = 1;
  }
}

main()
  .catch((err) => {
    console.error(`self-test failed: ${redact(err instanceof Error ? err.message : String(err))}`);
    process.exitCode = 1;
  })
  .finally(() => prisma.$disconnect());
