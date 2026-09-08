# Ghostty "hang" after global OOM — 2026-09-08

## Symptom

Ghostty windows stayed open but every terminal in them was dead: no output, no response to input. Ghostty itself was *not* frozen or deadlocked — PID 17725 was in state `S` with all 67 threads parked in `futex_do_wait` / `io_cqring_wait` / `poll`, averaging 1.5% CPU. Nothing was spinning and nothing was in `D` state.

The giveaway in the journal:

```
com.mitchellh.ghostty[17725]: warning(flatpak): signal send error: GDBus.Error:org.freedesktop.DBus.Error.UnixProcessIdUnknown: No such pid
```

Ghostty was signalling PTY children that no longer existed.

## Root cause

Ghostty is installed as a Flatpak, so it cannot fork shells directly. Every command it runs on the host goes over the `org.freedesktop.Flatpak.Development` D-Bus API, which means **every terminal session on the machine lands in one single cgroup: `flatpak-session-helper.service`**. Confirmed — the Ghostty scope itself holds only Ghostty and its dbus proxy, zero shells:

```
app-flatpak-com.mitchellh.ghostty-17614.scope
  17614 bwrap ... /app/bin/ghostty      17705 xdg-dbus-proxy
  17720 bwrap ... /app/bin/ghostty      17725 /app/bin/ghostty
```

The chain that killed everything:

1. A Python process started from a Ghostty tab grew to **10.8 GB resident / 18.5 GB virtual**. Combined with msedge, k3s, buzz/whisper and the rest, it exhausted 62 GB RAM *and* all 8 GB of swap.
2. The kernel fired a **global** OOM — note `constraint=CONSTRAINT_NONE ... global_oom`, so this was machine-wide, not a cgroup-limit breach. Victims were picked across the whole box:

   ```
   13:29:04  Killed process 2008248 (traefik)                       — k3s pod
   13:36:51  Killed process 64909, 64952 (traefik), 1798724 (coredns)
   13:36:51  Killed process 3937538 (python) anon-rss:10802628kB
             task_memcg=/user.slice/.../flatpak-session-helper.service
   ```

3. **This is the part that turned one dead process into every dead terminal.** The unit ran with systemd's default `OOMPolicy=stop`, which means: when the kernel OOM-kills *any single process* in a unit, systemd stops the *entire unit*. So systemd tore down all of `flatpak-session-helper.service`, `final-sigterm` timed out after 90 s, and at 13:38:21 it SIGKILLed the lot:

   ```
   13:38:21  flatpak-session-helper.service: State 'final-sigterm' timed out. Killing.
   13:38:21  Killing process 87138, 87471, 87514, 88029, 88049 (claude) with signal SIGKILL
             ... 88125 (npm exec chrome), 88127 (uv), 88128 (glab),
                 88220 (python3), 88796 (sh), 88799 (chrome-devtools), 88835 (node)
   13:38:21  Failed with result 'oom-kill'.
             Consumed ... 17.7G memory peak, 1.1G memory swap peak.
   ```

   `memory.peak` on the cgroup corroborates: **19.0 GB**.

4. The unit restarted clean at 13:38:21 with 2 tasks. Ghostty was never told its children died, so the surfaces just sat there.

### Secondary effect: the desktop also stuttered

Independent of the dead tabs, the box was I/O-saturated for a long stretch afterwards:

```
/proc/pressure/io:  some avg10=69.24   full avg10=40.78
Swap: 8.0Gi total, 8.0Gi used, 1.9Mi free     swappiness=60, no zram
```

`full=41%` means that for ~41% of wall-clock time *every* task on the machine was stalled on disk. Swap was 100% consumed and backed by `/swap.img` on the same saturated device, so all reclaim went into that queue. Ghostty's render thread waited in it like everything else. A plain `journalctl` query in this state took over 120 s. Contributors at the time: an `unzip` of `transcribe-linux-x86_64-cuda.zip` (62 MB/s read + 107 MB/s write), the buzz/whisper child at 2.7 GB RSS, msedge, k3s-server, ampscansvc.

Also logged, unrelated but symptomatic of general memory strain — NVIDIA GPU OOMs at 08:09 and 10:37 (`NV_ERR_NO_MEMORY`).

## Fix applied

`~/.config/systemd/user/flatpak-session-helper.service.d/oom.conf`:

```ini
[Service]
OOMPolicy=continue
```

This does not stop OOM kills — it stops systemd from escalating one kernel OOM-kill into a teardown of every terminal session. The kernel reaps the offending process; the rest survive.

Applied with `systemctl --user daemon-reload` and verified live **without restarting the unit** (restarting it would itself kill all running sessions — don't do that to apply config):

```
$ systemctl --user show flatpak-session-helper.service -p OOMPolicy -p DropInPaths
OOMPolicy=continue
DropInPaths=/home/markusg/.config/systemd/user/flatpak-session-helper.service.d/oom.conf
```

To revert: delete the drop-in and `systemctl --user daemon-reload`.

## Recovering killed sessions

The processes are unrecoverable — nothing from before the 13:38 sweep survived, and the helper cgroup came back holding only its own two tasks. But Claude Code streams every session to disk under `~/.claude/projects/<escaped-cwd>/<session-id>.jsonl`, so the *conversations* are intact and resumable. Transcripts whose last write lands in the 13:36–13:38 kill window:

| Last write | Size | Session ID | cwd to resume from |
|---|---|---|---|
| 13:36 | 11.2 MB | `95f55e03-5cf1-4d8d-bec4-dca9a5110959` | `~/Private/claude-experiments/astro-visuals` |
| 13:37 | 13.5 MB | `ad9ab24f-22d8-484b-8543-9372b5dad357` | `~/Private/claude-experiments/astro-visuals` |
| 13:36 | 982 KB | `126de4c2-e52d-468d-bd34-d135c4cabd40` | `~/Projects/Heinzel/shared` |
| 13:38 | 104 KB | `3f65ccf9-cabf-484a-af7e-2569c3ffe273` | `~/Projects/Heinzel/shared` |

Resume from the matching directory:

```bash
cd ~/Private/claude-experiments/astro-visuals
claude --resume ad9ab24f-22d8-484b-8543-9372b5dad357
```

Or `claude --resume` with no argument for the interactive picker. Uncommitted edits Claude had already written to disk are still there; anything that only existed in a pending tool call is gone.

## Further hardening worth considering

- **Swap is the real constraint.** 8 GB of file-backed swap against 62 GB RAM is thin for this workload, and once it filled, the machine had nowhere to go but OOM. Enlarging `/swap.img` or adding zram would raise the ceiling.
- **`MemoryHigh=` on the helper unit** would throttle reclaim before the machine reaches global OOM. Trade-off: the limit is shared across *all* terminal sessions collectively, so set it generously (e.g. 24–32 G) or it will slow down honest work.
- **A native Ghostty package instead of the Flatpak** removes the shared-cgroup problem entirely — each terminal gets its own scope, and one runaway process can only take itself down. This is the structural fix; the drop-in above is damage control for the Flatpak topology.
- **Watch the 10 GB Python.** The incident needed a single process at 10.8 GB to tip a 62 GB machine over. Whatever produced it is worth a memory cap of its own.

## Note on the Ghostty source side

`src/os/flatpak.zig` learns that a host process died *only* via the `HostCommandExited` D-Bus signal (subscribed at `start()`, handled in `onExit`, line ~457). When `flatpak-session-helper` is killed outright it never emits that signal, so `state` stays `.started` forever and the surface is never told to show an exit. That is why the tabs hung silently rather than reporting "process exited". A source-side fix would watch the `org.freedesktop.Flatpak` bus name and synthesise an exit for still-`.started` commands when the name vanishes. Not implemented — the systemd drop-in addresses the practical problem.
