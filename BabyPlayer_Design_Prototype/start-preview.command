#!/bin/zsh

launchctl remove com.babyplayer.design-preview 2>/dev/null || true
launchctl submit -l com.babyplayer.design-preview -- /usr/bin/python3 -m http.server 4173 --bind 127.0.0.1 --directory "/Users/wufengyu/Projects/AppleTV-儿童播放器/BabyPlayer_Design_Prototype"
open "http://127.0.0.1:4173/?screen=home"
