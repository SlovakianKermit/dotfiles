function opencode
    systemctl --user start supermemory.service 2>/dev/null
    sudo docker compose -f ~/.local/share/opencode-searchxng/docker/docker-compose.yml up -d --wait 2>/dev/null
    /usr/bin/opencode $argv
    if not pgrep -f "/usr/bin/opencode|^opencode" >/dev/null
        sudo docker compose -f ~/.local/share/opencode-searchxng/docker/docker-compose.yml stop 2>/dev/null
        systemctl --user stop supermemory.service 2>/dev/null
    end
end
