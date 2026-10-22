///|
/// `testdata/elf/tiny.amd64` and `tiny.arm64`: static executables of a few
/// hundred bytes made by the cross compilers (see tools/elf/make_samples.sh).
let tiny_amd64 : String = "f0VMRgIBAQAAAAAAAAAAAAIAPgABAAAAQAFAAAAAAABAAAAAAAAAAOABAAAAAAAAAAAAAEAAOAAEAEAABgAFAAEAAAAFAAAAAAAAAAAAAAAAAEAAAAAAAAAAQAAAAAAAfAEAAAAAAAB8AQAAAAAAAAAQAAAAAAAABAAAAAQAAAAgAQAAAAAAACABQAAAAAAAIAFAAAAAAAAgAAAAAAAAACAAAAAAAAAACAAAAAAAAABT5XRkBAAAACABAAAAAAAAIAFAAAAAAAAgAUAAAAAAACAAAAAAAAAAIAAAAAAAAAAIAAAAAAAAAFHldGQGAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAABAAAAAAAAAABAAAABAAAAAFAAAAR05VAAIAAMAEAAAAAwAAAAAAAADzDx76Dx9AAOv+AAAAAAAAFAAAAAAAAAABelIAAXgQARsMBwiQAQAAEAAAABwAAADQ////CgAAAAAAAABHQ0M6IChVYnVudHUgMTEuNC4wLTF1YnVudHUxfjIyLjA0LjMpIDExLjQuMAAALnNoc3RydGFiAC5ub3RlLmdudS5wcm9wZXJ0eQAudGV4dAAuZWhfZnJhbWUALmNvbW1lbnQAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAsAAAAHAAAAAgAAAAAAAAAgAUAAAAAAACABAAAAAAAAIAAAAAAAAAAAAAAAAAAAAAgAAAAAAAAAAAAAAAAAAAAeAAAAAQAAAAYAAAAAAAAAQAFAAAAAAABAAQAAAAAAAAoAAAAAAAAAAAAAAAAAAAAQAAAAAAAAAAAAAAAAAAAAJAAAAAEAAAACAAAAAAAAAFABQAAAAAAAUAEAAAAAAAAsAAAAAAAAAAAAAAAAAAAACAAAAAAAAAAAAAAAAAAAAC4AAAABAAAAMAAAAAAAAAAAAAAAAAAAAHwBAAAAAAAALQAAAAAAAAAAAAAAAAAAAAEAAAAAAAAAAQAAAAAAAAABAAAAAwAAAAAAAAAAAAAAAAAAAAAAAACpAQAAAAAAADcAAAAAAAAAAAAAAAAAAAABAAAAAAAAAAAAAAAAAAAA"

///|
let tiny_arm64 : String = "f0VMRgIBAQAAAAAAAAAAAAIAtwABAAAAsABAAAAAAABAAAAAAAAAADgBAAAAAAAAAAAAAEAAOAACAEAABQAEAAEAAAAFAAAAAAAAAAAAAAAAAEAAAAAAAAAAQAAAAAAA4AAAAAAAAADgAAAAAAAAAAAQAAAAAAAAUeV0ZAYAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAEAAAAAAAAAAAAAAUAAAAABAAAAAAAAAAAXpSAAR4HgEbDB8AEAAAABgAAADc////BAAAAAAAAABHQ0M6IChVYnVudHUgMTEuNC4wLTF1YnVudHUxfjIyLjA0LjMpIDExLjQuMAAALnNoc3RydGFiAC50ZXh0AC5laF9mcmFtZQAuY29tbWVudAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAsAAAABAAAABgAAAAAAAACwAEAAAAAAALAAAAAAAAAABAAAAAAAAAAAAAAAAAAAABAAAAAAAAAAAAAAAAAAAAARAAAAAQAAAAIAAAAAAAAAuABAAAAAAAC4AAAAAAAAACgAAAAAAAAAAAAAAAAAAAAIAAAAAAAAAAAAAAAAAAAAGwAAAAEAAAAwAAAAAAAAAAAAAAAAAAAA4AAAAAAAAAAtAAAAAAAAAAAAAAAAAAAAAQAAAAAAAAABAAAAAAAAAAEAAAADAAAAAAAAAAAAAAAAAAAAAAAAAA0BAAAAAAAAJAAAAAAAAAAAAAAAAAAAAAEAAAAAAAAAAAAAAAAAAAA="

///|
fn elf_config(arch : String, extra : String) -> @spec.Config raise {
  @spec.Config::parse(
    "{\"name\":\"demo\",\"version\":\"1\",\"arch\":\"\{arch}\",\"maintainer\":\"J <j@example.org>\",\"description\":\"Demo\"\{extra},\"contents\":[{\"src\":\"prog\",\"dst\":\"/usr/bin/prog\",\"mode\":\"0755\"},{\"src\":\"note\",\"dst\":\"/usr/share/doc/demo/note\"}]}",
  )
}

///|
fn elf_files(program : Bytes) -> Map[String, Bytes] {
  { "prog": program, "note": b"hello\n" }
}

///|
fn message_of(config : @spec.Config, files : Map[String, Bytes]) -> String? {
  try config.resolve(files) catch {
    err => Some("\{err}")
  } noraise {
    _ => None
  }
}

///|
test "an arm64 program in an amd64 package is refused, naming the file and both architectures" {
  let arm = @base64.decode(tiny_arm64)
  match message_of(elf_config("amd64", ""), elf_files(arm)) {
    Some(message) => {
      assert_true(message.contains("contents[0]"))
      assert_true(message.contains("/usr/bin/prog"))
      assert_true(message.contains("arm64"))
      assert_true(message.contains("amd64"))
      assert_true(message.contains("allow_arch_mismatch"))
    }
    None => fail("the mismatch was not noticed")
  }
  // The same file is fine in a package for its own architecture, in any spelling.
  assert_eq(message_of(elf_config("aarch64", ""), elf_files(arm)), None)
  assert_eq(message_of(elf_config("arm64", ""), elf_files(arm)), None)
  let amd = @base64.decode(tiny_amd64)
  assert_eq(message_of(elf_config("x86_64", ""), elf_files(amd)), None)
}

///|
test "allow_arch_mismatch lets a cross-built or foreign file through" {
  let arm = @base64.decode(tiny_arm64)
  let config = elf_config("amd64", ",\"allow_arch_mismatch\":true")
  assert_true(config.allow_arch_mismatch)
  assert_eq(message_of(config, elf_files(arm)), None)
  let plain = elf_config("amd64", "")
  assert_false(plain.allow_arch_mismatch)
  assert_eq(
    message_of({ ..plain, allow_arch_mismatch: true, }, elf_files(arm)),
    None,
  )
  assert_eq(config.elf_warnings(elf_files(arm)), [])
}

///|
test "allow_arch_mismatch must be a boolean" {
  try elf_config("amd64", ",\"allow_arch_mismatch\":\"yes\"") catch {
    err => assert_true("\{err}".contains("allow_arch_mismatch"))
  } noraise {
    _ => fail("expected an error")
  }
  assert_false(
    elf_config("amd64", ",\"allow_arch_mismatch\":null").allow_arch_mismatch,
  )
}

///|
test "an architecture independent package with an ELF file gets a warning, not an error" {
  let arm = @base64.decode(tiny_arm64)
  let config = elf_config("all", "")
  assert_eq(message_of(config, elf_files(arm)), None)
  let warnings = config.elf_warnings(elf_files(arm))
  assert_eq(warnings.length(), 1)
  assert_true(warnings[0].contains("contents[0]"))
  assert_true(warnings[0].contains("arm64"))
  assert_true(warnings[0].contains("\"all\""))
  // No ELF file, nothing to say; and a specific architecture has no such warning.
  assert_eq(config.elf_warnings(elf_files(b"#!/bin/sh\n")), [])
  assert_eq(elf_config("arm64", "").elf_warnings(elf_files(arm)), [])
  assert_eq(
    elf_config("all", ",\"allow_arch_mismatch\":true").elf_warnings(
      elf_files(arm),
    ),
    [],
  )
}

///|
test "files that only look like ELF, or are for an unknown CPU, are not an error" {
  // Just the magic number: the reader refuses it, the check does not make a fuss.
  assert_eq(
    message_of(elf_config("amd64", ""), elf_files(b"\x7fELF\x02\x01\x01")),
    None,
  )
  assert_eq(
    elf_config("all", "").elf_warnings(elf_files(b"\x7fELF\x02\x01\x01")),
    [],
  )
  // Machine 999: no package architecture, so nothing to compare.
  let odd = @base64.decode(tiny_amd64).to_array()
  odd[18] = 0xe7
  odd[19] = 0x03
  let odd_bytes = Bytes::from_array(odd)
  assert_eq(message_of(elf_config("amd64", ""), elf_files(odd_bytes)), None)
  let warnings = elf_config("all", "").elf_warnings(elf_files(odd_bytes))
  assert_eq(warnings.length(), 1)
  assert_true(warnings[0].contains("machine 999"))
}
