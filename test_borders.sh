#!/bin/bash
RST="\033[0m"
GRAY="\033[38;5;240m"
PANEL_W=72

# Test 1: \033[72G
echo "Test 1: column jump"
printf "${GRAY}╭"
for ((i=0; i<PANEL_W-2; i++)); do printf "─"; done
printf "╮${RST}\n"

printf "${GRAY}│${RST}  Some text with emoji 🚨 and ANSI \033[1;31mRED\033[0m\033[%dG${GRAY}│${RST}\n" "$PANEL_W"

# Test 2: using manual padding
echo "Test 2: manual padding"
text="Some text with emoji 🚨 and ANSI RED"
vlen=36 # visual length
pad=$(( PANEL_W - 4 - vlen ))
printf "${GRAY}│${RST}  %b%*s  ${GRAY}│${RST}\n" "$text" "$pad" ""
