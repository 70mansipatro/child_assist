// Sends one of Child Assist's fixed notifications to an account, for operators and for checking
// delivery end to end on a real phone. Only built-in templates can be sent: no free text, so no
// personal data can end up in a push.
//
//   npm run notify:send -- --email someone@example.com [--template test] [--link location]
//
// Templates: test (default), app-update, review-settings.
// --link (test template only): notifications, security, permissions, locationPermission, location,
// chat, documents, photos.
import "dotenv/config";
import { prisma } from "../lib/prisma";
import { notifyUser } from "../modules/notifications/notification.service";
import { DeepLink, templates, type NotificationContent } from "../modules/notifications/notification.types";

function arg(name: string): string | undefined {
  const i = process.argv.indexOf(`--${name}`);
  return i >= 0 ? process.argv[i + 1] : undefined;
}

function contentFor(template: string, link: string | undefined): NotificationContent {
  switch (template) {
    case "test": {
      if (link === undefined) return templates.test();
      if (!(link in DeepLink)) throw new Error(`Unknown --link. Use one of: ${Object.keys(DeepLink).join(", ")}`);
      return templates.test(DeepLink[link as keyof typeof DeepLink]);
    }
    case "app-update":
      return templates.appUpdate();
    case "review-settings":
      return templates.reviewSettings();
    default:
      throw new Error("Unknown --template. Use test, app-update or review-settings.");
  }
}

async function main(): Promise<void> {
  const email = arg("email")?.trim().toLowerCase();
  if (!email) throw new Error("--email is required");
  const content = contentFor(arg("template") ?? "test", arg("link"));

  const user = await prisma.user.findUnique({ where: { email }, select: { id: true } });
  if (!user) throw new Error("No account with that email");
  const devices = await prisma.notificationDevice.count({ where: { userId: user.id, enabled: true } });
  const outcome = await notifyUser(user.id, content);
  console.log(JSON.stringify({ registeredDevices: devices, ...outcome }));
}

main()
  .catch((err) => {
    console.error(err instanceof Error ? err.message : String(err));
    process.exitCode = 1;
  })
  .finally(() => prisma.$disconnect());
