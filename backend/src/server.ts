import "dotenv/config";
import { createApp } from "./app";
import { prisma } from "./lib/prisma";
import { pushConfig, smtpConfig } from "./config/env";
import { settleNotifications } from "./modules/notifications/notification.service";

const app = createApp();
const PORT = Number(process.env.PORT) || 3000;

async function start(): Promise<void> {
  try {
    await prisma.$connect();
    console.log("Connected to PostgreSQL");
  } catch (err) {
    console.error("Failed to connect to PostgreSQL", err);
    process.exit(1);
  }

  const smtp = smtpConfig();
  if (smtp.error) {
    console.warn(`Email is not configured (${smtp.error}): registration cannot send verification codes.`);
  }
  const push = pushConfig();
  if (push.error) {
    console.warn(`Push notifications are not configured (${push.error}): notifications are saved to history only.`);
  }

  const server = app.listen(PORT, () => {
    console.log(`Child Assist backend listening on http://localhost:${PORT}`);
  });

  const shutdown = async (signal: string): Promise<void> => {
    console.log(`${signal} received, shutting down`);
    server.close();
    await settleNotifications();
    await prisma.$disconnect();
    process.exit(0);
  };

  process.on("SIGINT", () => void shutdown("SIGINT"));
  process.on("SIGTERM", () => void shutdown("SIGTERM"));
}

void start();
