source /usr/share/cachyos-fish-config/cachyos-config.fish

# overwrite greeting
# potentially disabling fastfetch
#function fish_greeting
#    # smth smth
#end
set -gx SHELL /bin/bash

function update --description "Update repo, AUR and flatpak packages (AUR diffs AI-reviewed)"
    set -l skip_ai 0
    for arg in $argv
        switch $arg
            case --skip-ai
                set skip_ai 1
            case -h --help
                echo "usage: update [--skip-ai]"
                return 0
            case '*'
                echo "update: unknown argument: $arg" >&2
                return 2
        end
    end

    if test $skip_ai -eq 0
        aur-review
        or begin
            echo "update: AUR review did not clear — no packages were upgraded." >&2
            return 1
        end
    end

    paru -Syu --noconfirm --skipreview --noupgrademenu
    or return $status
    flatpak update -y
end
