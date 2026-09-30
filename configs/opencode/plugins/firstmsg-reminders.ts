import { Plugin } from "@opencode/plugin"

const REMINDERS = [
  "REMINDERS:",
  "- When ssh'ing via any alias from ~/.ssh/config (proxmox, laptop, valheim, odysseus-lxc, odysseus-docker), pass `-o RemoteCommand=none -o RequestTTY=no`. Those configs set RemoteCommand (fish / docker exec) which hangs non-interactive ssh.",
  "- User scripts live in ~/.local/bin.",
  "- ~/dotfiles is a GitHub push mirror only - never write to it or treat it as the source of truth. Edit the live files (e.g. ~/.local/bin, ~/.local/share/man, ~/.config/...) and let dotfiles-sync.sh push mirror them.",
].join("\n")

const seen = new Set<string>()

export default Plugin.define({
  id: "firstmsg-reminders",
  async setup(ctx) {
    await ctx.session.hook("prompt", (event) => {
      const id = (event as { sessionID?: string }).sessionID
      if (!id || seen.has(id)) return
      seen.add(id)
      event.prompt.text = `${event.prompt.text}\n\n${REMINDERS}`
    })
  },
})
