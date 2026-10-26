// notchroom: a pixel office in the MacBook notch, seen from above. Every Claude Code session is a character
// and every recently active project has its own desk. See README.md for the tour.
//
// Sources:
//   App.swift       the notch panel: placement, opening and closing, reload timers
//   Room.swift      the room: who stands where, walking, the cat, drawing it open or collapsed
//   Cards.swift     hover cards and speech bubbles
//   Pixels.swift    colors, cached bitmaps and text, sprites
//   Hook.swift      `--hook`: turns Claude Code hook events into state files
//   Sessions.swift  sessions, projects, desks, focusing a terminal
//   Answer.swift    Allow / Deny from the notch to a waiting hook, over signature-checked XPC
//   Ideas.swift     per-project ideas from `claude -p`, filing them in stash
//   Today.swift     today's numbers (the clock's card)
//   Sky.swift       sun position and weather
//   Music.swift     what resona is playing
//   Install.swift   adding and removing the hooks in ~/.claude/settings.json
//   Paths.swift     where state lives, the config file
//   SelfTest.swift  `--test`
import AppKit

let usage = """
usage: notchroom                    run the notch (make install starts it at login)
       notchroom --hook             read one Claude Code hook event on stdin
       notchroom --install-hooks    add notchroom's hooks to ~/.claude/settings.json
       notchroom --uninstall-hooks  remove them again
       notchroom --test             run the self-check
"""

switch CommandLine.arguments.dropFirst().first {
case nil: runApp()
case "--hook": hook()
case "--test": test()
case "--install-hooks": setHooks(install: true)
case "--uninstall-hooks": setHooks(install: false)
case "-h", "--help": print(usage)
default: print(usage); exit(2)
}
