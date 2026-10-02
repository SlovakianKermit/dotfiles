function opencode
    docker compose -f ~/.local/share/opencode-searchxng/docker/docker-compose.yml up -d 2>/dev/null &
    disown $last_pid
    systemctl --user start supermemory.service 2>/dev/null &
    disown $last_pid
    /usr/bin/opencode $argv

    # Count only interactive clients. The persistent `opencode serve --service`
    # daemon must not count, or the cleanup below would never run.
    set -l clients (pgrep -fa '/usr/bin/opencode' | grep -v -- '--service')
    if test (count $clients) -eq 0
        # Stop the shared background server (and any MCP children it owns).
        /usr/bin/opencode service stop 2>/dev/null
        docker compose -f ~/.local/share/opencode-searchxng/docker/docker-compose.yml stop 2>/dev/null
        systemctl --user stop supermemory.service 2>/dev/null
    end
end
