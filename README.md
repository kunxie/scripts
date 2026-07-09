# Host Update Script

`host-updates.sh` runs routine host package updates and writes a timestamped log
to `~/logs`.

On macOS it updates Homebrew formulae, upgrades non-privileged Homebrew casks,
skips casks that are likely to require an administrator password, and updates
tools managed by `mise`.

## Run Manually

```sh
./host-updates.sh
```

If needed, make it executable first:

```sh
chmod +x /Users/kunxie/scripts/host-updates.sh
```

## Recommended Crontab

Running every 3 hours is frequent enough to keep command-line tools current
without making package updates run constantly.

Edit your user crontab:

```sh
crontab -e
```

Add this entry:

```cron
SHELL=/bin/zsh
PATH=/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin

0 */3 * * * /Users/kunxie/scripts/host-updates.sh
```

The schedule means: run at minute `0`, every 3 hours, every day.

The script already logs to files like:

```text
~/logs/host-updates-YYYYMMDD-HHMMSS.log
```

## Notes

- The script avoids privileged Homebrew casks, so normal cron runs should not
  stop on a macOS password prompt.
- Skipped privileged casks are listed in the script log.
- If a network download fails during `mise upgrade`, the script retries before
  reporting a failure.
