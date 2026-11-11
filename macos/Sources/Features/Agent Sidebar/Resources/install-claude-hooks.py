#!/usr/bin/env python3
"""agent-sidebar: add (or remove) the sidebar status hooks in Claude Code.

    install-claude-hooks.py            install into ~/.claude/settings.json
    install-claude-hooks.py --remove   remove them again
    install-claude-hooks.py --print    show the resulting settings, change nothing

The hook script is copied to ~/.ghostty-agents/bin/ghostty-agent-hook so the
hooks keep working when this checkout moves. Existing hooks are kept; a backup
of settings.json is written next to it before the first change.

An existing statusLine command is wrapped by ghostty-agent-statusline, which
saves the context window numbers and then runs the original command; --remove
puts the original command back. Without a statusLine nothing is added.
"""
import argparse
import json
import os
import shlex
import shutil
import sys
import time

MARKER = "ghostty-agent-hook"
# Claude Code hook event -> (sidebar state, pass the hook payload through?)
EVENTS = {
    "SessionStart": ("idle", True),
    "UserPromptSubmit": ("working", False),
    "PreToolUse": ("working", False),
    "Notification": ("waiting", True),
    "Stop": ("done", True),
    "StopFailure": ("error", True),
    "SessionEnd": ("ended", False),
}


def strip(hooks):
    """Remove every hook entry this installer added."""
    for event in list(hooks):
        groups = []
        for group in hooks[event]:
            if not isinstance(group, dict):
                groups.append(group)
                continue
            kept = [h for h in group.get("hooks", []) if MARKER not in str(h.get("command", ""))]
            if kept:
                groups.append({**group, "hooks": kept})
        if groups:
            hooks[event] = groups
        else:
            del hooks[event]


STATUSLINE = "ghostty-agent-statusline"


def unwrap_statusline(settings):
    """Put back the status line command the wrapper was given."""
    line = settings.get("statusLine")
    if not isinstance(line, dict) or STATUSLINE not in str(line.get("command", "")):
        return
    try:
        parts = shlex.split(line["command"])
    except ValueError:
        parts = []
    if len(parts) > 1:
        line["command"] = parts[1]
    else:
        del settings["statusLine"]


def wrap_statusline(settings, wrapper):
    line = settings.get("statusLine")
    if not isinstance(line, dict) or line.get("type", "command") != "command":
        return
    command = line.get("command")
    if isinstance(command, str) and command.strip():
        line["command"] = f"'{wrapper}' {shlex.quote(command)}"


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--remove", action="store_true")
    parser.add_argument("--print", dest="dry", action="store_true")
    parser.add_argument("--settings", default=os.path.expanduser("~/.claude/settings.json"))
    parser.add_argument("--home", default=os.path.expanduser("~/.ghostty-agents"))
    args = parser.parse_args()

    settings = {}
    if os.path.exists(args.settings):
        with open(args.settings) as f:
            text = f.read()
        try:
            settings = json.loads(text) if text.strip() else {}
        except ValueError as error:
            sys.exit(f"{args.settings} is not valid JSON ({error}); fix it first, nothing was changed.")
    if not isinstance(settings, dict):
        sys.exit(f"{args.settings} does not contain a JSON object; nothing was changed.")

    hooks = settings.setdefault("hooks", {})
    if not isinstance(hooks, dict):
        sys.exit(f'"hooks" in {args.settings} is not an object; nothing was changed.')
    strip(hooks)
    unwrap_statusline(settings)

    installed = os.path.join(args.home, "bin", "ghostty-agent-hook")
    if not args.remove:
        for event, (state, with_payload) in EVENTS.items():
            command = f"'{installed}' claude {state}" + ("" if with_payload else " nopayload")
            hooks.setdefault(event, []).append({"hooks": [{"type": "command", "command": command}]})
        wrap_statusline(settings, os.path.join(args.home, "bin", STATUSLINE))
    if not hooks:
        del settings["hooks"]

    result = json.dumps(settings, indent=2, ensure_ascii=False) + "\n"
    if args.dry:
        sys.stdout.write(result)
        return

    if not args.remove:
        here = os.path.dirname(os.path.abspath(__file__))
        os.makedirs(os.path.dirname(installed), exist_ok=True)
        for name in ("ghostty-agent-hook", STATUSLINE):
            target = os.path.join(os.path.dirname(installed), name)
            shutil.copyfile(os.path.join(here, name), target)
            os.chmod(target, 0o755)

    os.makedirs(os.path.dirname(args.settings), exist_ok=True)
    if os.path.exists(args.settings):
        backup = f"{args.settings}.backup-{time.strftime('%Y%m%d-%H%M%S')}"
        shutil.copyfile(args.settings, backup)
        print(f"backup: {backup}")
    tmp = args.settings + ".tmp"
    with open(tmp, "w") as f:
        f.write(result)
    os.replace(tmp, args.settings)
    print(("removed sidebar hooks from " if args.remove else "installed sidebar hooks into ") + args.settings)
    if not args.remove:
        print("Restart running Claude Code sessions to pick the hooks up.")


if __name__ == "__main__":
    main()
