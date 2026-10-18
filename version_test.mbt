///|
test "version is a semantic version" {
  let parts = @linuxpkg.VERSION.split(".").to_array()
  assert_eq(parts.length(), 3)
}
