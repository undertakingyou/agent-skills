# agent-skills

Personal collection of Claude Code skills, portable across machines.

## Install via Claude Code plugin (recommended)

Add to your `~/.claude/settings.json`:

```json
{
  "extraKnownMarketplaces": {
    "undertakingyou": {
      "source": {
        "source": "github",
        "repo": "undertakingyou/agent-skills"
      }
    }
  },
  "enabledPlugins": {
    "agent-skills@undertakingyou": true
  }
}
```

Then restart Claude Code. Skills will be available immediately and update when the plugin updates.

## Install via symlink (other tools)

```bash
git clone https://github.com/undertakingyou/agent-skills.git
cd agent-skills
./install.sh
```

This symlinks each skill directory into `~/.claude/skills/` so any tool that reads from there picks them up. Run `install.sh` again after pulling new skills.

## Adding a skill

```bash
mkdir skills/my-new-skill
# Edit skills/my-new-skill/SKILL.md
```

## Structure

```
.claude-plugin/marketplace.json   # Claude Code marketplace manifest
plugin/
  .claude-plugin/plugin.json      # Plugin metadata
  hooks/hooks.json                # Hook definitions (if any)
skills/
  my-skill/SKILL.md               # Your skills go here
install.sh                        # Symlink installer for non-plugin use
```
