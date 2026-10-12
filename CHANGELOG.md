# Changelog

Versions follow semver as described under "Versioning" in `README.md`.

## 1.1.0

- The image identifies its build: `sram_dump VERSION (BRANCH, DATE)` at boot,
  from `version.sh` (git tag, commit, branch and commit date).
- Monitor command `I` returns the same identification. `V` is unchanged.
- Banner files may use `@VERSION@`, `@BRANCH@` and `@DATE@` as well as `@BAUD@`.
- `make` rebuilds when the commit, banner or baud changes, and only then. The
  standalone and slot builds share one staging rule.

## 1.0.0

The first build proven on silicon: it dumped the full 256 KB configuration of
a base RLC-Club v2.15, burned as slot 2 of the append-only boot ROM.

- CS0 is programmed for the SRAM as an **8-bit** port (the SRAMs sit on D15–D8
  only). Earlier builds used a 16-bit port and read even bytes only.
- Append-only boot ROM: slot stub, slot builds, no-erase patching
  (`make patch`, `rom_patch.py`).
- Cow monitor (`g` after the banner): `V R W X J S`, using no RAM.
- External DS1232 watchdog strobed throughout; clock set to 16.78 MHz; 19200
  baud by default.
