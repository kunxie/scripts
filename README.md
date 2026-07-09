# Host Update Script

`host-updates.sh` runs routine host package updates and writes a timestamped
log to `~/logs`.

On macOS, it updates Homebrew formulae, upgrades non-privileged Homebrew casks,
skips casks that are likely to require an administrator password, and updates
tools managed by `mise`.

On Ubuntu-like Linux hosts, it updates apt packages and updates tools managed by
`mise`. apt updates run only when the script is already root or `sudo` can run
without a password prompt.

## Run Manually

```sh
./host-updates.sh
```

If needed, make it executable first:

```sh
chmod +x "$HOME/scripts/host-updates.sh"
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
0 */3 * * * "$HOME/scripts/host-updates.sh"
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
- On Linux, apt updates are skipped and counted as a failure unless the script
  runs as root or `sudo -n true` succeeds.
- If a network download fails during `mise upgrade`, the script retries before
  reporting a failure.
