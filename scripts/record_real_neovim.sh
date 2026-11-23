#!/usr/bin/env bash
set -e

# Record real Neovim session into an asciinema cast
python3 -m asciinema rec --overwrite -c "nvim -u tests/minit.lua -l scripts/interactive_session.lua" assets/real_session.cast
