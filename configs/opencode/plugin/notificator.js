// notificator.js
import { fileURLToPath } from "url";
import { dirname, join } from "path";
import { readFileSync, readdirSync } from "fs";
var __filename = fileURLToPath(import.meta.url);
var __dirname = dirname(__filename);
function stripJsonComments(str) {
  return str.replace(/\/\/.*$/gm, "").replace(/\/\*[\s\S]*?\*\//g, "");
}
function loadConfig() {
  try {
    const configPath = join(__dirname, "notificator.jsonc");
    const content = readFileSync(configPath, "utf-8");
    const stripped = stripJsonComments(content);
    return JSON.parse(stripped);
  } catch (err) {
    console.error("Failed to load notificator.jsonc config:", err.message);
    return {};
  }
}
function hashString(str) {
  let hash = 0;
  for (let i = 0; i < str.length; i++) {
    const char = str.charCodeAt(i);
    hash = (hash << 5) - hash + char;
    hash = hash & hash;
  }
  return Math.abs(hash);
}
function getSoundFiles() {
  try {
    const soundsDir = join(__dirname, "notificator-sounds");
    const files = readdirSync(soundsDir).filter((f) => /\.(mp3|wav|ogg|m4a|aac|flac)$/i.test(f)).sort();
    return files.length > 0 ? files : ["ding1.mp3"];
  } catch {
    return ["ding1.mp3"];
  }
}
function pickSoundFile(projectPath, seed) {
  const soundFiles = getSoundFiles();
  const input = `${projectPath}:${seed}`;
  const hash = hashString(input);
  const index = hash % soundFiles.length;
  return soundFiles[index];
}
var currentSessionID = null;
var lastWasAbort = false;
var lastNotifyAt = 0;
function getEventSessionID(event) {
  if (!event)
    return null;
  if (event.sessionID)
    return event.sessionID;
  if (event.properties?.sessionID)
    return event.properties.sessionID;
  if (event.properties?.info?.id)
    return event.properties.info.id;
  return null;
}
var NotificationPlugin = async ({ project, client, $, directory, worktree }) => {
  const config = loadConfig();
  const enabled = config.enabled !== false;
  const configuredDebounceMs = Number(config.debounceMs);
  const debounceMs = Number.isFinite(configuredDebounceMs) && configuredDebounceMs >= 0 ? configuredDebounceMs : 1500;
  const desktopNotificationConfig = config.showDesktopNotification || {};
  const desktopNotificationEnabled = desktopNotificationConfig.enabled !== false;
  const soundConfig = config.playSound || {};
  const soundEnabled = soundConfig.enabled !== false;
  const configuredVolume = Number(soundConfig.volume ?? 100);
  const soundVolume = Number.isFinite(configuredVolume) ? Math.min(100, Math.max(0, configuredVolume)) : 100;
  let soundFile;
  if (soundConfig.file) {
    soundFile = soundConfig.file;
  } else if (soundConfig.fileSeed !== void 0) {
    soundFile = pickSoundFile(worktree || directory, soundConfig.fileSeed);
  } else if (currentSessionID !== null) {
    soundFile = pickSoundFile(worktree || directory, currentSessionID);
  } else {
    soundFile = pickSoundFile(worktree || directory, hashString(worktree || directory));
  }
  const playNotificationSound = async () => {
    if (!enabled || !soundEnabled)
      return;
    const soundPath = join(__dirname, "notificator-sounds", soundFile);
    const platform = process.platform;
    try {
      if (platform === "darwin") {
        await $`afplay -v ${soundVolume / 100} ${soundPath}`.quiet();
      } else if (platform === "linux") {
        await $`ffplay -nodisp -autoexit -loglevel quiet -volume ${soundVolume} ${soundPath}`.quiet();
      }
    } catch (err) {
    }
  };
  const sendNotification = async (title, message) => {
    if (!enabled || !desktopNotificationEnabled)
      return;
    const platform = process.platform;
    try {
      if (platform === "darwin") {
        const escapedMessage = message.replace(/'/g, `'"'"'`);
        const escapedTitle = title.replace(/'/g, `'"'"'`);
        await $`osascript -e 'display notification "${escapedMessage}" with title "${escapedTitle}"'`;
      } else if (platform === "linux") {
        await $`notify-send ${title} ${message}`;
      }
    } catch (err) {
      console.error("Failed to send notification:", err.message);
    }
  };
  const notify = async (title, message) => {
    const now = Date.now();
    if (debounceMs > 0 && now - lastNotifyAt < debounceMs)
      return;
    lastNotifyAt = now;
    await sendNotification(title, message);
    await playNotificationSound();
  };
  return {
    event: async ({ event }) => {
      const eventSessionID = getEventSessionID(event);
      if (event.type === "session.created" && eventSessionID) {
        currentSessionID = eventSessionID;
        lastWasAbort = false;
      }
      if (event.type === "session.error" && eventSessionID === currentSessionID) {
        lastWasAbort = true;
      }
      if (event.type === "session.idle" && eventSessionID === currentSessionID) {
        const wasAbort = lastWasAbort;
        lastWasAbort = false;
        if (!wasAbort) {
          await notify("OpenCode", "Generation completed");
        }
      }
    },
    "permission.ask": async (input, output) => {
      const message = `Permission request: ${input.type}`;
      await notify("OpenCode", message);
    }
  };
};
export {
  NotificationPlugin
};
//# sourceMappingURL=notificator.js.map
