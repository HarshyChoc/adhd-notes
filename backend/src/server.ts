import { buildApp } from "./app.js";
import { config } from "./config.js";

const app = await buildApp();

try {
  await app.listen({
    port: config.PORT,
    host: config.BIND_HOST,
  });
  app.log.info(`MD Sticky Notes backend listening on ${config.BIND_HOST}:${config.PORT}`);
} catch (error) {
  app.log.error(error);
  process.exit(1);
}
