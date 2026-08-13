#!/bin/zsh

zmx_choose() {
        local display
        display=$(zmx list 2>/dev/null | while read -r line; do
                name="" pid="" clients="" dir=""

                for part in ${(z)line}; do
                        case $part in
                        name=*) name=${part#*=} ;;
                        pid=*) pid=${part#*=} ;;
                        clients=*) clients=${part#*=} ;;
                        start_dir=*) dir=${part#*=} ;;
                        esac
                done

                printf "%s\tpid:%s\tclients:%s\tdir:%s\n" "$name" "$pid" "$clients" "$dir"
        done)

        local output query key selected session_name
        output=$(
                { [[ -n "$display" ]] && echo "$display"; } | fzf \
                        --delimiter=$'\t' \
                        --with-nth=1,2,3,4 \
                        --print-query \
                        --expect=ctrl-n \
                        --height=80% \
                        --reverse \
                        --prompt="zmx> " \
                        --header="Enter: select | Ctrl-N: create new" \
                        --preview='zmx history {1}' \
                        --preview-window=right:60%:follow
        )
        local rc=$?

        query=$(echo "$output" | sed -n '1p')
        key=$(echo "$output" | sed -n '2p')
        selected=$(echo "$output" | sed -n '3p')

        if [[ "$key" == "ctrl-n" && -n "$query" ]]; then
                session_name="$query"
        elif [[ $rc -eq 0 && -n "$selected" ]]; then
                session_name=$(echo "$selected" | awk '{print $1}')
        elif [[ -n "$query" ]]; then
                session_name="$query"
        else
                return 130
        fi

        zmx attach "$session_name"
}

zmx_choose