import "dotenv/config";
import { z } from "zod";

const baseConfigSchema = z.object({
  BIND_HOST: z.string().min(1).default("127.0.0.1"),
  PORT: z.coerce.number().int().positive().default(8787),
  DATABASE_URL: z.string().min(1),
  SYNC_PROVIDER: z.enum(["google", "mock"]).default("google"),
  APP_DESKTOP_REDIRECT_URI: z.string().min(1).default("mdstickynotes://auth/callback"),
  APP_ENCRYPTION_KEY: z.string().min(1),
  SESSION_TTL_DAYS: z.coerce.number().int().positive().default(30),
  GOOGLE_SYNC_INTERVAL_MS: z.coerce.number().int().positive().default(15000),
  MOCK_USER_EMAIL: z.string().email().default("local-dev@mdstickynotes.dev"),
  ALLOWED_GOOGLE_EMAILS: z.string().default(""),
  INTERNAL_CRON_AUDIENCE: z.string().default(""),
  INTERNAL_CRON_SERVICE_ACCOUNT_EMAIL: z.string().default(""),
});

const googleConfigSchema = z.object({
  GOOGLE_CLIENT_ID: z.string().min(1),
  GOOGLE_CLIENT_SECRET: z.string().min(1),
  GOOGLE_REDIRECT_URI: z.string().url(),
});

const mockConfigSchema = z.object({
  GOOGLE_CLIENT_ID: z.string().default(""),
  GOOGLE_CLIENT_SECRET: z.string().default(""),
  GOOGLE_REDIRECT_URI: z.string().default("http://127.0.0.1:8787/auth/google/callback"),
});

export type AppConfig =
  | (z.infer<typeof baseConfigSchema> & z.infer<typeof googleConfigSchema> & { SYNC_PROVIDER: "google" })
  | (z.infer<typeof baseConfigSchema> & z.infer<typeof mockConfigSchema> & { SYNC_PROVIDER: "mock" });

const baseConfig = baseConfigSchema.parse(process.env);

export const config: AppConfig = baseConfig.SYNC_PROVIDER === "google"
  ? {
      ...baseConfig,
      ...googleConfigSchema.parse(process.env),
      SYNC_PROVIDER: "google",
    }
  : {
      ...baseConfig,
      ...mockConfigSchema.parse(process.env),
      SYNC_PROVIDER: "mock",
    };
