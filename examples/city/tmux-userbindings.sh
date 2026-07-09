#!/bin/sh
# tmux-userbindings.sh — re-apply Jeremy's custom mouse/scroll + clipboard bindings
# on the gc tmux server.
#
# Why this exists: agents run on a dedicated gc tmux server (socket named after the city)
# that does NOT load ~/.tmux.conf. gc's per-session hooks (tmux-theme.sh /
# tmux-keybindings.sh) re-assert gc's environment on every session create/reconcile,
# leaving tmux's DEFAULT WheelUpPane binding — which yanks the wheel into copy-mode
# instead of handing scroll to full-screen TUI apps (Claude). This hook is wired into
# session_live (see your city pack.toml [global]) so the custom
# bindings are re-applied on every session and survive reconciles/server restarts.
#
# Bindings are server-global, so re-applying per session is idempotent + cheap.

# Same socket resolution the gastown theme scripts use.
gcmux() { tmux ${GC_TMUX_SOCKET:+-L "$GC_TMUX_SOCKET"} "$@"; }

# Wheel-up: hand the scroll to full-screen apps that request the mouse (Claude);
# otherwise enter copy-mode to scroll tmux's scrollback. The mouse_any_flag check is
# the bit the stock binding lacks.
gcmux bind-key -n WheelUpPane if-shell -Ft= '#{||:#{pane_in_mode},#{mouse_any_flag}}' 'send-keys -M' 'copy-mode -e'

# On mouse-drag release in copy-mode, copy the selection to the macOS clipboard and exit.
gcmux bind-key -T copy-mode    MouseDragEnd1Pane send-keys -X copy-pipe-and-cancel 'pbcopy'
gcmux bind-key -T copy-mode-vi MouseDragEnd1Pane send-keys -X copy-pipe-and-cancel 'pbcopy'

exit 0
