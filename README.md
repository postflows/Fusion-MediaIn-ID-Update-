# Fusion MediaIn ID Update

A Lua script for DaVinci Resolve that fixes broken Fusion compositions and Fusion effects after a timeline or project is moved to another project.

Part of the [PostFlows](https://github.com/postflows) toolkit.

---

## The Problem

If you've ever built a Fusion composition in DaVinci Resolve that uses clips from the Media Pool — and then tried to copy that composition (or the entire timeline) to another project — you've probably run into this:

**Media Offline.**

This is a well-known and widely reported issue in the DaVinci Resolve community ([Blackmagic Forum thread from 2020](https://forum.blackmagicdesign.com/viewtopic.php?f=21&t=119229), [and many others](https://forum.blackmagicdesign.com/viewtopic.php?f=22&t=135565)). The root cause is the way `MediaIn` nodes identify their media.

Every time a file is added to a project's Media Pool, DaVinci Resolve assigns it a unique **Media ID** — a UUID that is specific to that project. When you transfer a Fusion composition to a new project (even if all the same files are present and relinked on the Media page), the `MediaIn` nodes still hold references to the **old Media IDs** from the source project. Since those IDs don't exist in the new project, Resolve cannot resolve the links, and the composition renders black.

The same happens inside **Fusion effects** applied to clips — for example a Fusion effect on an Adjustment Clip with an extra video added inside it. These links are invisible on the Edit page and, until Resolve 21.1.2, could not be reached by scripts at all.

### Common scenarios where this happens

- Copying a Fusion composition or a timeline between projects
- Moving a project to another workstation or machine
- Using shared Fusion templates or motion graphics across multiple projects
- Duplicating a project as a starting point for a new one
- Sending a project to a collaborator or a post-production facility

### Why there's no built-in fix

`MediaIn` nodes are unique to the Fusion page inside DaVinci Resolve (as opposed to standalone Fusion Studio, which uses `Loader` nodes instead). They are tied to the Media Pool of a single project, and Blackmagic Design has not provided a relinking tool for them. The only official workaround is to delete and re-add every `MediaIn` node by hand — which also resets trim, loop and Global In/Out settings.

---

## The Solution

The script finds every `MediaIn` node that points to the Media Pool and re-links it to the matching clip of the current project, keeping trim, loop and all other node settings.

### What it scans

- Fusion compositions of all clips on video tracks (all compositions of a clip, not only the first one)
- Fusion effects applied to clips, including Adjustment Clips — **Resolve 21.1.2+** (on older versions this part is skipped and reported)
- All timelines of the project, or only the current one

### How a clip is matched

For each `MediaIn` node the first rule that fits wins:

1. **Media ID still exists in the pool** — nothing to do
2. **Same file path** — re-link to that clip
3. **Same clip name or file name, and it is unique** — re-link to that clip
4. **File still exists on disk** — import it into the `Fusion MediaIn Restored` bin, then re-link

Several clips with the same name and no path match are reported as **ambiguous** and left untouched.

### Safe by design

- Only `MediaIn` nodes with `MediaSource = MediaPool` are touched. The built-in input of a clip or an effect (`MediaSource = Timeline`) is never modified.
- Each changed composition gets one undo step ("Fix MediaIn IDs").
- Every change is verified after it is applied.
- `DRY_RUN` mode reports what would change without changing anything.
- Running the script again is harmless: fixed links are reported as "Already OK".

---

## Settings

At the top of the script:

```lua
local CONFIG = {
    ALL_TIMELINES   = true,   -- false: current timeline only
    INCLUDE_EFFECTS = true,   -- scan Fusion effects on clips (Resolve 21.1.2+)
    IMPORT_MISSING  = true,   -- import files missing from the pool by their stored path
    IMPORT_BIN      = "Fusion MediaIn Restored",
    DRY_RUN         = false,  -- true: report only, change nothing
}
```

---

## Requirements

- DaVinci Resolve with Lua scripting
- **21.1.2 or newer** to fix links inside Fusion effects (compositions of clips work on older versions too)

---

## Installation & Usage

1. Copy `Fusion MediaID fix.lua` to your DaVinci Resolve scripts folder:

   | Platform | Path |
   |---|---|
   | macOS | `~/Library/Application Support/Blackmagic Design/DaVinci Resolve/Fusion/Scripts/Utility/` |
   | Windows | `%APPDATA%\Blackmagic Design\DaVinci Resolve\Fusion\Scripts\Utility\` |
   | Linux | `~/.local/share/DaVinciResolve/Fusion/Scripts/Utility/` |

2. Open the project with the broken Fusion compositions.

3. Optional: run once with `DRY_RUN = true` to see what will change.

4. Go to **Workspace → Scripts → Utility → Fusion MediaID fix**.

5. Check the results in **Workspace → Console**.

---

## Console Output Example

```
========================================
Fusion MediaIn ID Update v2
========================================

IMPORTED + RELINKED
  AI_for_Meds_R2_v03 | V2 | Adjustment Clip @ 00:04:15:03 | fx WippCam | MediaIn2
  Clip: AIMed_lists_BG_loop30.mov
  Path: /Volumes/WD_Black/Infaprim/AI Medical/Collect/Заставки/AIMed_lists_BG_loop30.mov
  ID:   970d96e0-7f73-462d-9cd4-13981f265fe1 -> 2a673c1e-5ea7-43ea-b2c0-7bb4b61d97bc

RELINKED (path)
  API_TEST | V2 | Adjustment Clip @ 00:04:15:03 | fx WippCam | MediaIn2
  Clip: AIMed_lists_BG_loop30.mov
  Path: /Volumes/WD_Black/Infaprim/AI Medical/Collect/Заставки/AIMed_lists_BG_loop30.mov
  ID:   970d96e0-7f73-462d-9cd4-13981f265fe1 -> 2a673c1e-5ea7-43ea-b2c0-7bb4b61d97bc

========================================
  Timelines / clips / comps: 5 / 240 / 76
  Already OK:          0
  Relinked by path:    2
  Relinked by name:    0
  Imported + relinked: 1
  Ambiguous name:      0
  Missing file:        0
========================================
```

---

## Limitations

- **Fusion Clips** from the Media Pool are not scanned: their compositions are not reachable through the scripting API.
- **Audio tracks** are not scanned (Fusion compositions and effects live on video items).
- **`Loader` nodes** use a plain file path, not a Media ID, and are not affected by this problem.
- If a file was moved on disk, the stored path is outdated: import the file into the pool yourself (name matching will then find it) or relink it on the Media page first.

---

## Changelog

**v2**
- Fusion effects on clips, including Adjustment Clips (Resolve 21.1.2+)
- All timelines of the project, all compositions of a clip
- Matching by file path first, then by unique name
- Import of missing files by their stored path
- `DRY_RUN` mode, undo step per composition, verified writes
- Fixed: `MediaIn` nodes with `MediaSource = Timeline` could be overwritten by name matching
- Fixed: an empty clip name stopped processing of the remaining nodes of that clip

**v1**
- Fusion compositions on the current timeline, matching by file name

---

MIT License. Free to use, modify, and distribute.
