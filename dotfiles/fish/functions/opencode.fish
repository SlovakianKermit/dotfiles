function opencode
    docker compose -f ~/.local/share/opencode-searchxng/docker/docker-compose.yml up -d 2>/dev/null &
    disown $last_pid
    systemctl --user start supermemory.service 2>/dev/null &
    disown $last_pid
    /usr/bin/opencode $argv
    if not pgrep -f "/usr/bin/opencode|^opencode" >/dev/null
        docker compose -f ~/.local/share/opencode-searchxng/docker/docker-compose.yml stop 2>/dev/null
        systemctl --user stop supermemory.service 2>/dev/null
    end
end
