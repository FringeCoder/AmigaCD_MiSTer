# AmigaCD

An Amiga CD32 / CDTV core for the [MiSTer board](https://github.com/MiSTer-devel),
forked from [Minimig-AGA_MiSTer](https://github.com/MiSTer-devel/Minimig-AGA_MiSTer)
by way of [kblood's native-akiko line](https://github.com/kblood/Minimig-AGA-cd32-cdtv-native-akiko).

It identifies itself as `AmigaCD` (`CONF_STR`, `Minimig.sv:39`) and runs beside a
stock Minimig install rather than replacing it. The userspace half lives in
[FringeCoder/AmigaCD](https://github.com/FringeCoder/AmigaCD) — several features
below are split across the two, and this file says which half does what.

**What this fork is for:** running CD32 and CDTV software the way the hardware
did — including from a real CD-ROM drive — with save states, real floppy drives,
and PSX pads on the SNAC port.

> **Read the status column.** A good deal of what follows is verified in
> simulation and has never run on hardware. The distinction is kept in every
> table here on purpose: this is a fork that moves fast, and "it compiles and the
> bench is green" is not the same claim as "it works".

---

## What this fork adds

Ours, unless a row says otherwise. Marked ✅ hardware-tested, 🧪 simulation only,
⏳ written but not yet fitted or run.

### Save states

| | |
|---|---|
| Four slots | Captured into a DDR3 window, written to SD by userspace. `rtl/ss_ctrl.v` |
| What is carried | Chip RAM, slow RAM, Zorro II fast RAM, the custom chipset register shadow, Denise's colour table, Akiko's registers, the CPU's architectural state |
| Integrity | CRC32 over the payload, plus a CRC over the Kickstart region — a state restored onto a different ROM is refused rather than run |
| Host state | CD drive position and what was playing travel beside the payload, since the core cannot see them |
| Status | ✅ save and restore confirmed on hardware (PAL, CD32 profile); the OSD progress bars and per-slot screenshots ⏳ |

The save-state UI is userspace: a progress bar while the file is written (a full
save is up to ~11.5 MB) and a screenshot of the moment saved, shown full-screen
while picking a slot.

### Input

| | |
|---|---|
| PSX pads on the SNAC user port | `rtl/snac_psx.v` — digital pads and DualShock analog. ✅ a pad navigates the Menu core and launches a core with no USB device attached (2026-08-06) |
| CD32 pad mapping | `rtl/snac_cd32.v` — the CD32's serial pad protocol driven from a PSX pad. 🧪 |
| GunCon light gun | The axes gate that lets a GunCon's coordinates through is benched; the gun itself ⏳. `docs/psx-snac-hardware.md` lists the checks that have not been run |
| Light pen / light gun | `agnus_beamcounter.v` latches VPOSR/VHPOSR, so BPLCON0 bit 3 no longer wedges the beam counters. 🧪 — the latch is benched, a gun that locks has never been tested |
| Analog stick as a mouse | Userspace, velocity-based. 🧪 |

The same SNAC reader is used by the [Menu core fork](https://github.com/FringeCoder/Menu_MiSTer),
which is what lets a PSX pad navigate the menu and launch a core with no USB
device attached. The module is vendored there from here; see
`docs/snac-psx-vendoring.md` in the userspace repo.

### Real floppy drives

Mr Floppy SNAC board support — real 3.5" drives reading real disks, wired into
`paula_floppy.v` beside the ADF path. The flux-select retiming is ours; the
drive-side RTL is RobSmithDev's (see below). ✅ two drives working.

### CD

| | |
|---|---|
| Physical CD-ROM drive | Userspace: a real drive in place of a CHD. ✅ a game boots from a real CD32 disc; the drive sustains ~351 sectors/s, and insert and eject are noticed |
| Per-game NVRAM | CD32 saves keyed to the disc — by ISO9660 volume label, or a TOC-geometry UUID for discs without one. ✅ both identity paths |
| CDDA | Audio streamed from the host into the core's FIFO. ✅ an audio disc plays through the CD32 BIOS player |
| Sector delivery floor | Paced to a declared minimum rather than as fast as the HPS can write. ⏳ |

Not yet exercised: either Real CD reset path, and everything CDTV on a real disc.

### Chipset accuracy

Each of these is benched in CI and every bench has been falsified — mutated so
the behaviour is wrong, to prove the check fails. 🧪 unless noted.

| | |
|---|---|
| ADKCON attach | Paula's audio channel modulation, absent before: `adkcon` was stored and read back but bits 0..7 were decoded nowhere |
| CIA leftovers | CIA-A port B, PB6/PB7 driven from the timers, CIA-B's serial register |
| Floppy `_READY` | A selected, spinning, *empty* drive no longer reports ready — software waiting for a disk was being told it had one. Drive ID shift register added |
| HHPOSR (`$DFF1DA`) | Decoded; it was not implemented at all |
| Gary decode audit | `$DC8000` overlap recorded, decodes audited against the hardware maps |
| Light pen latch | Fixed a hang class: VPOSR/VHPOSR were a combinational mux on the userspace-supplied position, so setting BPLCON0 bit 3 froze both registers and every beam-wait loop spun forever — with no gun connected they froze at zero, so it did not need a light pen to be involved. The bench counts distinct VHPOSR values across a frame: against the old code, one |
| DDR3 read return | A return arriving while `waitrequest` was high was dropped, wedging the memory port for good. Explains the Z2-fast-RAM-plus-CD black screen. ⏳ |
| NTSC long lines | Implemented, benched, and **shipped switched off** — correct behaviour that the MiSTer's fixed-rate scaler cannot carry. See `docs/core-accuracy-todo.md` T9 |

### Testing and tooling

22 checks on every push: a syntax gate that parses all 99 synthesisable sources
standalone, a guard against an upstream commit that keeps coming back and
stopping the CIA timers, and benches for the beam counter, light pen, sprites,
CIA, Paula, SDRAM, DDR3, the CPU wrapper, the CDTV bridge, Akiko, the save-state
register bus and the TG68K savestate restore.

Also a seed sweep that requires **both** slacks positive (`seed_sweep_both.sh`) —
the older scripts ranked on setup alone and would have shipped a build with
−0.5 ns hold.

---

## What this fork takes from other projects

Everything here is someone else's work. Where we changed it, the row says so.

| From | What | How it arrived |
|---|---|---|
| [MiSTer-devel/Minimig-AGA_MiSTer](https://github.com/MiSTer-devel/Minimig-AGA_MiSTer) | The core itself — the Amiga, and the CD32/CDTV chipset support including Akiko, the CDTV bridge and the host sector transport | Merged; synced through `da7632e` |
| [kblood/Minimig-AGA-cd32-cdtv-native-akiko](https://github.com/kblood/Minimig-AGA-cd32-cdtv-native-akiko) | This fork's parent line. Specific fixes taken: the chip-DMA slot guard (`114ab43`), the SPRxDATx write vs shift-register load ordering fix (`e6f8fbe`) | Cherry-picked with authorship preserved |
| [kblood/Main_MiSTer-cd32-cdtv](https://github.com/kblood/Main_MiSTer-cd32-cdtv) | The CD32/CDTV userspace driver and console OSD this fork's host half grew from | Userspace repo |
| [Anime0t4ku/Main_MiSTer_Physical_Disc](https://github.com/Anime0t4ku/Main_MiSTer_Physical_Disc) | Physical CD-ROM drive support — `support/physical_disc/` is a verbatim copy, re-extracted on each sync | Userspace repo |
| [RobSmithDev — MiSTer Floppy](https://mister.robsmithdev.co.uk) | `rtl/MiSTerFloppy*.v`, the real-floppy-drive RTL | Vendored as-is |
| [MiSTer-devel/Main_MiSTer](https://github.com/MiSTer-devel/Main_MiSTer) | The userspace the host half is a fork of | Userspace repo, synced through `0039110` |
| [Niklas Ekström — a314](https://github.com/niklasekstrom/a314) | The shared-folder Amiga driver | Inherited from Minimig-AGA |

Two more that shaped the work without contributing code:

- **[WinUAE](https://www.winuae.net/) (Toni Wilen)** is the behavioural reference
  for most of the accuracy work above. Where a fix cites `custom.cpp` or a WinUAE
  commit, that is why. It is a reference, not a source: nothing is copied from it.
- **[vAmigaTS](https://github.com/dirkwhoffmann/vAmigaTS)** publishes its own
  expected values, which is what lets the beam counter be scored without a
  reference Amiga to measure against.

And one deliberately **not** used: [theshaneobrien/mister-disc-drive-support](https://github.com/theshaneobrien/mister-disc-drive-support)
is a parallel physical-disc effort, watched for fixes but not merged — its engine
is a full rewrite of the same interface and switching would trade working code
for unexercised code. See `docs/upstream-pins.md` in the userspace repo.

The pins for every upstream, and the procedure for syncing them, are in
[`docs/upstream-pins.md`](https://github.com/FringeCoder/AmigaCD/blob/master/docs/upstream-pins.md).

---

## Core features supported

Inherited from Minimig-AGA, with this fork's additions marked **+**.

* Chipset variants : OCS, ECS, AGA, CD32, CDTV
* ChipRAM : 0.5MB - 2.0MB
* SlowRAM : 0.0MB - 1.5MB
* FastRAM : 0.0MB - 384MB
* CPU core : 68000, 68020
* Kickstart : 1.2, 1.3, 2.0, 3.0, 3.1, 3.1.4, 3.2 (256kB, 512kB & 1MB kickstart ROMs currently supported)
* HRTmon with custom registers mirror
* Floppy drives : 1-4 floppies (supports ADF floppy image format), with normal & turbo speeds
* **+ Real floppy drives** through the Mr Floppy SNAC board
* Up to 4 IDE devices
* CDROM, **+ from a real CD-ROM drive**
* **+ Save states**, four slots, with per-game NVRAM for CD32
* **+ PSX pads, DualShock and GunCon** on the SNAC user port
* Video standard : PAL / NTSC
* Supports almost all OCS/ECS/AGA custom resolutions
* RTG with up to 1920x1080 and 1600x1200 resolutions
* Peripherals : USB keyboards, USB mice, USB gamepads
* Serial connection to Linux with ability to connect to Internet.
* Ethernet A2065.
* Shared folder for rapid file exchange between Linux and Amiga.
* MIDI: both MiSTer internal emulation and external through USER_IO port (MT32-pi and generic MIDI device)
* Akiko chunk to planar implementation
* Mouse with wheel, **+ or a DualShock analog stick**

## Usage

Everything in this section is Minimig-AGA's and applies unchanged unless noted.

### Presets

Supported presets for most common Amiga models. You need to place Kickstart ROMs into Games/Amiga folder:
* A500.rom (KS v1.3)
* A600.rom (KS v2.05)
* A1200.rom (KS v3.1)
* CD32.rom + CD32_ext.rom (KS v3.1) (see CD32 and CDTV section)
* CDTV.rom + CDTV.rom (KS v1.3) (see CD32 and CDTV section)

While Kickstart versions above are recommended as most used in corresponding configs, it's not limited to that.
For other more advanced configs and non-listed hardware, additional OSD options and configuration Load/Save are available.

**This fork:** the AmigaCD OSD has a System row that switches between CD32, CDTV,
A500 and A1200, and each machine keeps its own settings — discs, hard disks, RAM
and ROM all survive a round trip through the row.

### Screen adjustment
Adjustment is initiated from OSD menu. 
Keyboard control:
* Cursor keys - top/left corner.
* ALT+Cursor keys - bottom/right corner.
* Enter - finish and store position.
* Backspace - reset do default.
* Esc - cancel and finish.

Positions are saved in the configuration file. Up to 64 different resolutions can be adjusted.

### Shared folder

All required files (and sources) are in extra/MiSTer_share.lha

Amiga driver is based on Niklas Ekström [a314](https://github.com/niklasekstrom/a314) driver.

On Amiga:
- copy dummy.device to DEVS:
- copy MountList to DEVS: (or add content from MountList to existing file)
- copy MiSTerFileSystem to L:
- open CLI and type there: mount share:
- MiSTer drive will appear on main WB screen. If it will work, then you can add this command into user-startup file, and it will be mounted at every boot.

On Linux side the folder is "shared" inside Amiga folder.

### RTG

* install [Picasso96.lha](http://aminet.net/package/driver/video/Picasso96) Choose uaegfx while installing.
* remove uaegfx (or whatever driver you choose in install) from SYS:Devs/Monitors
* extract [MiSTer_RTG.lha](https://github.com/MiSTer-devel/Minimig-AGA_MiSTer/raw/MiSTer/extra/rtg_driver/MiSTer_RTG.lha) and copy content to SYS:
* reboot

New video modes will appear in ScreenMode preference. For more screen modes use Picasso96Mode preference (attn: it has awkward interface!)

**Note: RTG outputs to HDMI primarily as it uses scaler.**
If you want to see RTG video on VGA output, then set vga_scaler=1 in MiSTer.ini.
RTG is available only for 68020 CPU.

### IDE and CDROM
By default up to 2 IDE devices are supported. For Secondary Master/Slave devices, you have to install either IDEFix97 (shareware, WB3.1/3.9) or AtapiMagic (freeware, WB 3.1.4/3.2).
Removable/CD mode allows to hot swap CDs.

### How to make a new HDF (HDD Image)
Only plain/raw HDF images are supported. WinUAE Dynamic HDF and Sparse File HDF formats are not supported.

1) Create an empty HDF file of required size on PC (ideally fill it by 0 if possible).
2) Copy it to MiSTer
3) Mount it as HDF on OSD, and also mount some adf with HDToolBox (for example install3.2.adf from OS3.2)
4) Boot that ADF
5) go to HDToolBox, then Change Drive Type -> Define New -> Read Configuration. Then Ok, Ok. Then Save Changes to Drive.
6) Press Partition Drive. Optionally delete MDH1 partition, expand MDH0 to full drive. Rename MDH0 to standard DH0 name, mark it as Bootable. Then OK, then Save Changes to Drive.
7) Exit, reboot.
8) After booting you will see DH0:Uninitialized. Format it from Workbench menu. You can use Quick format option.
9) Install required OS.

### CD32 and CDTV

For quick CD32 and CDTV game start from OSD menu you need to place following files into Games/Amiga folder:
* CD32: CD32.rom (Kickstart main ROM) and CD32_ext.rom (Extended CD32 ROM). Only one version set exists: KS 3.1 r40.060 + ExtROM r40.60
* CDTV: CDTV.rom (Kickstart main ROM) and CDTV_ext.rom (Extended CDTV ROM). Any version should work.

Instead of ROM+ExtROM, combined 1MB ROM is supported (*_ext.rom not required).
* CD32.rom: CD32_ext.rom+CD32.rom (1MB total)
* CDTV.rom: CDTV_ext.rom+CDTV_ext.rom+CDTV.rom[+CDTV.rom] (1MB total)

Besides original CD32 and CDTV use for games, these HW add-ons can be used in AmigaOS/Workbench as a CD drive, leaving all 4 IDE drives for HDD use.
Note1: enable either CD32 or CDTV, not both.
Note2: remove CD0(CD1-CD9) supporting files from devs:DOSDrivers as CD is fully handled by ExtROM.
You have to use appropriate ROM/ExtROM from CD32/CDTV to let AmigaOS recognize CD drive. Tested in AmigaOS v3.2.
CDTV mode is preferred because appropriate updated ROM and ExtROM v3.2 for CDTV are included in AmigaOS 3.2 installation CD.
Besides original CDTV HW config, you can use up to Amiga 1200 config (68020 + AGA + 2MB ChipRAM + 384MB FastRAM and A1200 KS ROM).
CD32 official KS 3.1 set of ROMs also work with AmigaOS 3.2 (remember to use IDEFix to access HDD >4GB).

### MIDI
Supported internal MiSTer emulation and external devices such as MT32-pi or generic MIDI though USER_IO.
For MIDI-IN support through USER_IO set UART mode to None in OSD settings.

**This fork:** MIDI and the SNAC pad reader share every user-port pin, so they are
mutually exclusive — selected at runtime, and the reader releases the bus the
moment it is switched off.

### Akiko
Chunk to planar engine of Akiko is supported. It requires SetAkiko util (from releases/WheelDriverAkiko.adf) to be executed.

### Mouse Wheel
To enable wheel support both WheelDriver and FreeWheel must be run from releases/WheelDriverAkiko.adf

### Software
To use the core, you will need a Kickstart ROM image file, which you can obtain by copying Kickstart ROM IC from your actual Amiga, or by buying an [Amiga Forever](http://www.amigaforever.com/) software pack. Minimig also supports the [AROS](http://aros.sourceforge.net/) Kickstart ROM replacement.

The core can read any ADF floppy images you place on the SD card, and HDF harddisk images, which can be created with [WinUAE](http://www.winuae.net/).

### Recommended config

* for ECS games / demos : CPU = 68000, Turbo=NONE, Chipset=ECS, ChipRAM=0.5MB, slowRAM=0.5MB, Kickstart 1.3
* for AGA games / demos : CPU = 68020, Turbo=NONE, Chipset=AGA, ChipRAM=2MB, SlowRAM=0MB, FastRAM=384MB, Kickstart 3.1

### Controlling the core

Keyboard special keys:

* F12         - OSD menu
* F11         - start monitor (HRTmon) if HRTmon is enabled in OSD menu (otherwise F11 is the Amiga HELP key)
* ScrollLock  - toggle keyoard only / mouse / joystick 1 / joystick 2 emulation on the keyboard (direction keys + LCTRL)

## Building and working on this core

```sh
bash syntax_check.sh    # parse every synthesisable source, seconds
```

Run it before proposing anything — nothing else parses `Minimig.sv` or `rtl/`
until Quartus does, 18 seconds into a fit.

Benches live in `rtl/sim/<area>/`, compile with `iverilog -g2012`, and print
`RUN: PASS`, which is what CI greps for. **Falsify a bench before trusting it:**
mutate the DUT so the behaviour is wrong and confirm the bench fails on the check
that names it. A check that has never failed has not been shown to test anything,
and checks here have been caught passing vacuously more than once — comparing
defaults against defaults, or never reaching the state they claimed to test.

Timing is closed with `seed_sweep_both.sh`, which requires both slacks positive.
The open accuracy and timing backlog, ranked and each item citing a file and
line, is [`docs/core-accuracy-todo.md`](docs/core-accuracy-todo.md).

## Keeping this file current

**This README is part of the work, not a description written once at the end.**
The fork moves, and a stale feature list is worse than none: it makes a reader
trust a status column that is no longer true.

Update it in the same commit as the change, not afterwards — the same habit
`docs/upstream-pins.md` asks for with pins, and for the same reason. Two things
in particular go stale silently:

- **The status marks.** ✅ / 🧪 / ⏳ are claims about evidence. When something
  is tested on hardware, the mark moves in the commit that records the test.
- **The attribution table.** Anything taken from another project gets a row when
  it arrives, with the commit it came from. Cherry-picks keep their original
  authorship in git; the table is what makes that visible to someone reading the
  repository rather than its history.

`docs/core-accuracy-todo.md` T19 tracks doc staleness across the repository and
names this file.

## Sources

This fork descends from [MiSTer-devel/Minimig-AGA_MiSTer](https://github.com/MiSTer-devel/Minimig-AGA_MiSTer),
whose own lineage follows.

This sourcecode is based on Rok Krajnc project ([minimig-de1](https://github.com/rkrajnc/minimig-de1)).

Original Minimig sources from Dennis van Weeren with updates by Jakub Bednarski are published on [Google Code](http://code.google.com/p/minimig/).

Some Minimig updates are published on the [Minimig Discussion Forum](http://www.minimig.net/), done by Sascha Boing.

ARM firmware updates and Minimig-tc64 port changes by Christian Vogelsang ([minimig_tc64](https://github.com/cnvogelg/minimig_tc64)) and A.M. Robinson ([minimig_tc64](https://github.com/robinsonb5/minimig_tc64)).

MiSTer project by Sorgelig ([MiSTer](https://github.com/MiSTer-devel)).

TG68K.C core by Tobias Gubener.

CD32/CDTV native Akiko line by kblood ([Minimig-AGA-cd32-cdtv-native-akiko](https://github.com/kblood/Minimig-AGA-cd32-cdtv-native-akiko)).

Physical disc support by Anime0t4ku ([Main_MiSTer_Physical_Disc](https://github.com/Anime0t4ku/Main_MiSTer_Physical_Disc)).

MiSTer Floppy by RobSmithDev ([mister.robsmithdev.co.uk](https://mister.robsmithdev.co.uk)).

## Links & more info

Further info about Minimig can be found on the [Minimig Discussion Forum](http://www.minimig.net/).

MiSTer board support & other cores on the [MiSTer Project Page](https://github.com/MiSTer-devel).

## License

Copyright © 2011 - 2016 Rok Krajnc (rok.krajnc@gmail.com)

Copyright © 2005 - 2015 Dennis van Weeren, Jakub Bednarski, Sascha Boing, A.M. Robinson, Tobias Gubener, Till Harbaum

Copyright © 2017 - 2020 Sorgelig (mister.devel@gmail.com)

MiSTer Floppy RTL (`rtl/MiSTerFloppy*.v`) Copyright © RobSmithDev 2022-2026.

This program is free software: you can redistribute it and/or modify
it under the terms of the GNU General Public License as published by
the Free Software Foundation, either version 3 of the License, or
(at your option) any later version.

This program is distributed in the hope that it will be useful,
but WITHOUT ANY WARRANTY; without even the implied warranty of
MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
GNU General Public License for more details.

You should have received a copy of the GNU General Public License
along with this program.  If not, see <http://www.gnu.org/licenses/>.
