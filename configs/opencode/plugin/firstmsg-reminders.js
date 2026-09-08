const seen = new Set();

export const FirstMsgReminders = async () => {
  return {
    "chat.message": async (input, output) => {
      if (seen.has(input.sessionID)) return;
      seen.add(input.sessionID);
      output.parts.push({
        id: `prt_reminders-${Date.now()}`,
        type: "text",
        synthetic: true,
        sessionID: input.sessionID,
        messageID: output.message.id,
        text: [
          "REMINDERS:",
          "- When ssh'ing via any alias from ~/.ssh/config (proxmox, laptop, valheim, odysseus-lxc, odysseus-docker), pass `-o RemoteCommand=none -o RequestTTY=no`. Those configs set RemoteCommand (fish / docker exec) which hangs non-interactive ssh.",
          "- User scripts live in ~/.local/bin.",
        ].join("\n"),
      });
    },
  };
};
