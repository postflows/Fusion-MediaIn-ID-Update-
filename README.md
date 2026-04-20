# Fusion MediaIn ID Update

A Lua script for DaVinci Resolve that automatically fixes broken Fusion compositions after transferring projects between machines or workstations.

---

## The Problem

If you've ever built a Fusion composition in DaVinci Resolve that uses clips from the Media Pool — and then tried to copy that composition (or the entire timeline) to another project — you've probably run into this:

**Media Offline.**

This is a well-known and widely reported issue in the DaVinci Resolve community ([Blackmagic Forum thread from 2020](https://forum.blackmagicdesign.com/viewtopic.php?f=21&t=119229), [and many others](https://forum.blackmagicdesign.com/viewtopic.php?f=22&t=135565)). The root cause is the way `MediaIn` nodes identify their media.

Every time a file is added to a project's Media Pool, DaVinci Resolve assigns it a unique **Media ID** — a UUID that is specific to that project. When you transfer a Fusion composition to a new project (even if all the same files are present and relinked on the Media page), the `MediaIn` nodes still hold references to the **old Media IDs** from the source project. Since those IDs don't exist in the new project, Resolve cannot resolve the links, and the composition breaks.

The frustrating part: the files are right there in your Media Pool. Resolve just can't connect the dots automatically.

### Common scenarios where this happens

- Copying a Fusion composition between projects
- Moving a project to another workstation or machine
- Using shared Fusion templates or motion graphics across multiple projects
- Duplicating a project as a starting point for a new one
- Sending a project to a collaborator or a post-production facility

### Why there's no built-in fix

`MediaIn` nodes are unique to the Fusion page inside DaVinci Resolve (as opposed to standalone Fusion Studio, which uses `Loader` nodes instead). They were designed to tightly integrate with the Media Pool of a single project, and Blackmagic Design has not provided an automated relinking tool for them when moving between projects. The only official workaround is to manually delete and re-add every `MediaIn` node — a tedious process that also resets trim, loop, and Global In/Out settings.

---

## The Solution

This script automates the fix entirely.

It scans the Media Pool of the **current project**, builds a lookup table of `filename → Media ID`, then iterates through all Fusion compositions on the timeline, finds every `MediaIn` node, and updates its Media ID to match the current project — all based on filename matching.

### Features

- Recursively scans all Media Pool folders and subfolders
- Processes all video tracks and all clips in the current timeline
- Skips nodes whose Media IDs are already up to date
- Reports files not found in the Media Pool
- Provides a clear summary log of all changes made
- Non-destructive: only updates nodes where a matching file is found

---

## Requirements

- DaVinci Resolve (any recent version with Lua scripting support)
- All media files must already be present in the **current project's Media Pool**

> **Note:** Before running the script, make sure you have imported all the required media files into the Media Pool of the target project and relinked them on the Media page. The script handles the Fusion side — it updates `MediaIn` node references to match the new Media IDs assigned by Resolve in the current project.

---

## Installation & Usage

1. Copy `Fusion_MediaIn_ID_Update.lua` to your DaVinci Resolve scripts folder:

   | Platform | Path |
   |---|---|
   | macOS | `~/Library/Application Support/Blackmagic Design/DaVinci Resolve/Fusion/Scripts/Utility/` |
   | Windows | `%APPDATA%\Blackmagic Design\DaVinci Resolve\Fusion\Scripts\Utility\` |
   | Linux | `~/.local/share/DaVinciResolve/Fusion/Scripts/Utility/` |

2. Open the project with the broken Fusion compositions in DaVinci Resolve.

3. Make sure all required media files are imported into the Media Pool.

4. Go to **Workspace → Scripts → Utility → Fusion_MediaIn_ID_Update**.

5. Check the console output (**Workspace → Console**) to see the results.

---

## Console Output Example

```
========================================
MediaPool Files:
  EV01006N_1.mov: 9ced6f03-0e86-4862-9704-c9502ef33cec
  EV01009N_1.mov: fd7aef20-b61d-45b2-b4ae-55c44957fa33
  ...
========================================

[MediaIn1]
  File:       EV01006N_1.mov
  Old ID:     4addedf7-d179-43a2-b5c4-d0a7779d81d0
  New ID:     9ced6f03-0e86-4862-9704-c9502ef33cec
  ✓ Media ID successfully updated.

========================================
  Updated:             1
  Already up to date:  0
  Not found in pool:   0
========================================
```

---

## Limitations

- Only processes the **currently active timeline**. If you have multiple timelines with broken compositions, switch to each one and run the script again.
- Matching is done by **filename only**. If you have multiple files with the same name in different subfolders, only one will be matched (the last one found during the scan).
- Only `MediaIn` nodes are updated. `Loader` nodes (used in Fusion Studio) are not affected and do not need this fix.

---


MIT License. Free to use, modify, and distribute.
